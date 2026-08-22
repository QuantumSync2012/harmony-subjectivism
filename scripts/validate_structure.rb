#!/usr/bin/env ruby
# frozen_string_literal: true

# リポジトリパスは非ASCIIを含むため、filesystem encodingがUTF-8でないlocaleでは自分をUTF-8で再実行する
if Encoding.find("filesystem") != Encoding::UTF_8 && !ENV["HS_VALIDATOR_UTF8_REEXEC"]
  require "rbconfig"
  exec({ "LC_ALL" => "en_US.UTF-8", "HS_VALIDATOR_UTF8_REEXEC" => "1" }, RbConfig.ruby, __FILE__, *ARGV)
end

require "pathname"
require "set"
require "uri"
require "yaml"
require_relative "lib/concept_quote_gate"

ROOT = Pathname.new(__dir__).parent.expand_path
REGISTRY = ROOT.join("research/hs-id-registry.yaml")
ID_PATTERN = /\AHS-C-\d{4}\z/
ANCHOR_PATTERN = /<a\s+id=["']([^"']+)["']><\/a>/

STUBS = {
  "docs/glossary.md" => "canon/glossary.md",
  "docs/principles.md" => "canon/principles.md",
  "docs/motivation.md" => "guide/why-needed.md",
  "docs/intro.md" => "guide/ten-articles.md",
  "docs/faq.md" => "wiki/faq.md",
  "docs/positioning.md" => "wiki/positioning.md",
  "docs/heart-sutra.md" => "wiki/heart-sutra.md"
}.freeze

errors = []
unless ConceptQuoteGate.run(write: false, quiet: true).zero?
  errors << "concept definition quote gate failed (run scripts/sync_definition_quotes.rb --check for details)"
end
registry = YAML.load_file(REGISTRY)
entries = registry.fetch("entries")
by_id = entries.each_with_object({}) do |entry, memo|
  id = entry["id"]
  errors << "invalid concept ID: #{id.inspect}" unless id.is_a?(String) && ID_PATTERN.match?(id)
  errors << "duplicate concept ID: #{id}" if memo.key?(id)
  memo[id] = entry
end

entries.each do |entry|
  id = entry.fetch("id")
  status = entry["status"]
  errors << "#{id}: invalid status #{status.inspect}" unless %w[active retired].include?(status)
  errors << "#{id}: active_revision required for active entry" if status == "active" && !entry["active_revision"].is_a?(Integer)
  errors << "#{id}: last_revision required for retired entry" if status == "retired" && !entry["last_revision"].is_a?(Integer)

  if (successor = entry["superseded_by"])
    target = by_id[successor]
    errors << "#{id}: missing superseded_by target #{successor}" unless target
    errors << "#{id}: self-supersede" if successor == id
    errors << "#{id}: reverse supersedes link missing on #{successor}" if target && target["supersedes"] != id
  end
  if (predecessor = entry["supersedes"])
    target = by_id[predecessor]
    errors << "#{id}: missing supersedes target #{predecessor}" unless target
    errors << "#{id}: self-supersede" if predecessor == id
    errors << "#{id}: reverse superseded_by link missing on #{predecessor}" if target && target["superseded_by"] != id
  end

  locator = entry["path"]
  unless locator.is_a?(String) && locator.include?("#")
    errors << "#{id}: path with anchor is required"
    next
  end
  relative, anchor = locator.split("#", 2)
  target = ROOT.join(relative).cleanpath
  errors << "#{id}: path escapes repository" unless target.to_s.start_with?(ROOT.to_s + File::SEPARATOR)
  errors << "#{id}: missing path #{relative}" unless target.file?
  if target.file? && !target.read.include?(%(<a id="#{anchor}"></a>))
    errors << "#{id}: missing declared anchor ##{anchor} in #{relative}"
  end
  errors << "#{id}: anchor must be lowercase ID" unless anchor == id.downcase
end

by_id.each_key do |start|
  seen = Set.new
  cursor = start
  while (next_id = by_id[cursor] && by_id[cursor]["superseded_by"])
    if seen.include?(next_id)
      errors << "supersede cycle detected from #{start}"
      break
    end
    seen << next_id
    cursor = next_id
  end
end

active_ids = entries.select { |entry| entry["status"] == "active" }.map { |entry| entry["id"] }.sort
retired_ids = entries.select { |entry| entry["status"] == "retired" }.map { |entry| entry["id"] }.sort
pilot = registry.fetch("pilot_selection")
errors << "pilot active set differs from registry active set" unless pilot.fetch("proposed_active_ids").sort == active_ids
errors << "pilot retired exclusion differs from registry retired set" unless pilot.fetch("excluded_from_pilot").sort == retired_ids

anchor_locations = Hash.new { |hash, key| hash[key] = [] }
# 監査値(link/anchor数)をcheckout間で再現可能にするため、git管理下ではtracked filesに固定する
# (untracked・ignoredのmdが件数を揺らす)。.gitが無い展開先(git archive等)ではglobへフォールバック
tracked_markdown =
  if ROOT.join(".git").exist?
    IO.popen(["git", "-C", ROOT.to_s, "ls-files", "-z", "--", "*.md"]) { |io| io.read }
      .split("\0").map { |path| ROOT.join(path).to_s }
  end
source_markdown_files = (tracked_markdown || Dir.glob(ROOT.join("**/*.md"))).sort.reject do |file|
  Pathname.new(file).relative_path_from(ROOT).to_s.start_with?("generated/")
end

source_markdown_files.each do |file|
  File.foreach(file).with_index(1) do |line, line_number|
    line.scan(ANCHOR_PATTERN) do |match|
      anchor_locations[match.first] << "#{Pathname.new(file).relative_path_from(ROOT)}:#{line_number}"
    end
  end
end
anchor_locations.each do |anchor, locations|
  errors << "duplicate anchor #{anchor}: #{locations.join(', ')}" if locations.length > 1
end

STUBS.each do |old_path, new_path|
  old_file = ROOT.join(old_path)
  new_file = ROOT.join(new_path)
  label = new_path
  expected = "> このページは v1.0.0 で [#{label}](../#{new_path}) へ移転した。\n"
  errors << "missing compatibility stub #{old_path}" unless old_file.file?
  errors << "missing canonical target #{new_path}" unless new_file.file?
  errors << "stub drift: #{old_path}" if old_file.file? && old_file.read != expected
end

local_link_count = 0
source_markdown_files.each do |file|
  in_fence = false
  File.foreach(file).with_index(1) do |line, line_number|
    if line.lstrip.start_with?("```")
      in_fence = !in_fence
      next
    end
    next if in_fence

    line.scan(/\[[^\]]*\]\(([^)]+)\)/) do |match|
      raw_target = match.first.strip
      raw_target = raw_target[1..-2] if raw_target.start_with?("<") && raw_target.end_with?(">")
      next if raw_target.empty? || raw_target.start_with?("#")
      next if raw_target.match?(/\A(?:https?|mailto|data):/i)

      path_part, fragment = raw_target.split("#", 2)
      path_part = path_part.split("?", 2).first
      begin
        path_part = URI.decode_www_form_component(path_part)
      rescue ArgumentError
        errors << "invalid URL encoding in #{Pathname.new(file).relative_path_from(ROOT)}:#{line_number}: #{raw_target}"
        next
      end
      target = Pathname.new(file).dirname.join(path_part).cleanpath
      local_link_count += 1
      unless target.exist?
        errors << "broken local link in #{Pathname.new(file).relative_path_from(ROOT)}:#{line_number}: #{raw_target}"
        next
      end
      if fragment&.start_with?("hs-") && target.file? && !target.read.include?(%(<a id="#{fragment}"></a>))
        errors << "missing HS anchor in #{Pathname.new(file).relative_path_from(ROOT)}:#{line_number}: #{raw_target}"
      end
    end
  end
end

if errors.empty?
  puts "PASS: #{entries.length} registry entries, #{anchor_locations.length} unique anchors, #{STUBS.length} compatibility stubs, #{local_link_count} local links"
  exit 0
end

warn "FAIL: #{errors.length} structural error(s)"
errors.each { |error| warn "- #{error}" }
exit 1
