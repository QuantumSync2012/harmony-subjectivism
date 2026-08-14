#!/usr/bin/env ruby
# frozen_string_literal: true

require "pathname"
require "yaml"

ROOT = Pathname.new(__dir__).parent.expand_path
REGISTRY = YAML.load_file(ROOT.join("research/hs-id-registry.yaml"))
ENTRIES = REGISTRY.fetch("entries").each_with_object({}) { |entry, memo| memo[entry.fetch("id")] = entry }
WRITE_MODE = ARGV.delete("--write")

def definition_line(entry)
  relative, anchor = entry.fetch("path").split("#", 2)
  source = ROOT.join(relative).read
  anchor_line = %(<a id="#{anchor}"></a>)
  offset = source.index(anchor_line)
  raise "#{entry.fetch('id')}: source anchor not found" unless offset

  tail = source[(offset + anchor_line.length)..]
  line = tail.each_line.map(&:strip).find { |candidate| candidate.start_with?("**定義**:") }
  raise "#{entry.fetch('id')}: canonical definition line not found" unless line

  [relative, line]
end

errors = []
checked = 0
Dir.glob(ROOT.join("wiki/concepts/*.md")).sort.each do |filename|
  text = File.read(filename)
  next unless text.start_with?("---\n")

  frontmatter = text.split("---\n", 3)[1]
  entity_ref = frontmatter[/^entity_ref:\s*(HS-C-\d{4})\s*$/, 1]
  next unless entity_ref

  entry = ENTRIES[entity_ref]
  unless entry
    errors << "#{Pathname.new(filename).relative_path_from(ROOT)}: unknown entity_ref #{entity_ref}"
    next
  end

  begin_marker = "<!-- HS-DEF-QUOTE:BEGIN id=#{entity_ref}"
  block_pattern = /<!-- HS-DEF-QUOTE:BEGIN id=#{Regexp.escape(entity_ref)}[^\n]* -->\n.*?\n<!-- HS-DEF-QUOTE:END -->/m
  unless text.include?(begin_marker) && text.match?(block_pattern)
    errors << "#{Pathname.new(filename).relative_path_from(ROOT)}: definition quote block missing"
    next
  end

  relative, line = definition_line(entry)
  revision = entry.fetch("active_revision")
  expected = [
    "<!-- HS-DEF-QUOTE:BEGIN id=#{entity_ref} revision=#{revision} source=#{relative} -->",
    "> #{line}",
    "<!-- HS-DEF-QUOTE:END -->"
  ].join("\n")

  if text.match(block_pattern)[0] != expected
    if WRITE_MODE
      File.write(filename, text.sub(block_pattern, expected))
    else
      errors << "#{Pathname.new(filename).relative_path_from(ROOT)}: definition quote drift"
    end
  end
  checked += 1
end

if errors.empty?
  action = WRITE_MODE ? "synchronized" : "verified"
  puts "PASS: #{action} #{checked} generated definition quote block(s)"
  exit 0
end

warn "FAIL: #{errors.length} definition quote error(s)"
errors.each { |error| warn "- #{error}" }
exit 1
