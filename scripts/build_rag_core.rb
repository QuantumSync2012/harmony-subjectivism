#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "pathname"
require "rbconfig"

ROOT = Pathname.new(File.expand_path("..", __dir__))
OUTPUT = ROOT.join("generated/rag/core")
PACK_VERSION = "1.1.1"

EXACT_SOURCES = %w[
  README.md
  OPEN_QUESTIONS.md
  canon/glossary.md
  canon/principles.md
  guide/ten-articles.md
  guide/why-needed.md
  wiki/faq.md
  wiki/heart-sutra.md
  wiki/positioning.md
].freeze

GLOB_SOURCES = %w[
  wiki/concepts/*.md
  wiki/comparisons/*.md
].freeze

FORBIDDEN_SOURCE_PREFIXES = %w[
  raw/
  en/
  zh-Hant/
  docs/
].freeze

FORBIDDEN_CONTENT = {
  "external note URL" => %r{https?://note\.com/}i,
  "withdrawn matter definition" => /現のうち、?源則に律される部分(?:が|＝)物質/,
  "withdrawn fire definition" => /火\s*[＝=]\s*意識/,
  "withdrawn coined term" => /信火/
}.freeze

def sources
  paths = EXACT_SOURCES.map { |path| ROOT.join(path) }
  GLOB_SOURCES.each do |pattern|
    paths.concat(Dir.glob(ROOT.join(pattern)).map { |path| Pathname.new(path) })
  end
  paths.uniq.sort_by { |path| path.relative_path_from(ROOT).to_s }
end

def authority_for(relative)
  case relative
  when %r{\Acanon/}
    "current_canon"
  when "guide/ten-articles.md"
    "current_canon_summary"
  when "README.md", "guide/why-needed.md"
    "current_public_entry"
  when "OPEN_QUESTIONS.md"
    "current_open_questions"
  when %r{\Awiki/concepts/}
    "current_canon_checked_explanation"
  when %r{\Awiki/comparisons/}, "wiki/positioning.md"
    "source_scoped_comparison"
  else
    "current_canon_checked_explanation"
  end
end

def status_for(relative)
  relative == "OPEN_QUESTIONS.md" ? "open_questions" : "current"
end

def output_name(relative)
  relative.sub(/\.md\z/, "").gsub("/", "__") + ".md"
end

def strip_frontmatter(text)
  text.sub(/\A---\n.*?\n---\n/m, "")
end

def prepare_for_rag(relative, text)
  prepared = strip_frontmatter(text)
  return prepared unless relative == "canon/glossary.md"

  prepared.sub(
    /\n## 三、不採用・廃語台帳\n.*?\n---\n\n(?=## 四、)/m,
    "\n"
  )
end

def transformation_for(relative)
  relative == "canon/glossary.md" ? "retired_ledger_excluded" : "frontmatter_removed"
end

def validate_source!(relative, text)
  if FORBIDDEN_SOURCE_PREFIXES.any? { |prefix| relative.start_with?(prefix) }
    raise "forbidden source path: #{relative}"
  end

  FORBIDDEN_CONTENT.each do |label, pattern|
    raise "#{label} in #{relative}" if text.match?(pattern)
  end

  if text.include?("public_raw_dialogue: true")
    raise "raw dialogue marked public in #{relative}"
  end
end

sync_check = ROOT.join("scripts/sync_definition_quotes.rb")
unless system(RbConfig.ruby, sync_check.to_s, "--check", chdir: ROOT.to_s)
  abort "FAIL: canonical definition quote check failed; core RAG was not rebuilt"
end

FileUtils.mkdir_p(OUTPUT)
Dir.glob(OUTPUT.join("*.md")).each { |path| File.delete(path) }
manifest_path = OUTPUT.join("manifest.json")
File.delete(manifest_path) if manifest_path.exist?

entries = sources.map do |source|
  raise "missing source: #{source}" unless source.file?

  relative = source.relative_path_from(ROOT).to_s
  source_text = source.read(encoding: "UTF-8")
  rag_text = prepare_for_rag(relative, source_text)
  validate_source!(relative, rag_text)

  source_sha = Digest::SHA256.hexdigest(source_text)
  target = OUTPUT.join(output_name(relative))
  metadata = <<~YAML
    ---
    generated: true
    do_not_edit: true
    rag_pack: harmonious-subjectivism-core
    rag_pack_version: #{PACK_VERSION}
    authority: #{authority_for(relative)}
    status: #{status_for(relative)}
    source_path: #{relative}
    source_sha256: #{source_sha}
    transformation: #{transformation_for(relative)}
    ---

  YAML
  target.write(metadata + rag_text, encoding: "UTF-8")

  {
    "file" => target.relative_path_from(ROOT).to_s,
    "sha256" => Digest::SHA256.file(target).hexdigest,
    "source_path" => relative,
    "source_sha256" => source_sha,
    "transformation" => transformation_for(relative),
    "authority" => authority_for(relative),
    "status" => status_for(relative)
  }
end

manifest = {
  "pack" => "harmonious-subjectivism-core",
  "pack_version" => PACK_VERSION,
  "language" => "ja",
  "scope" => "current Japanese canon-checked public explanations",
  "excluded" => [
    "raw dialogue",
    "dictionary raw transcription",
    "historical translations",
    "v0.1.1 publication tree",
    "retired or rejected definitions as current answers"
  ],
  "files" => entries
}
manifest_path.write(JSON.pretty_generate(manifest) + "\n", encoding: "UTF-8")

puts "Built #{entries.length} RAG document(s) in #{OUTPUT}"
puts "Manifest: #{manifest_path}"
