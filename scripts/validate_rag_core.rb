#!/usr/bin/env ruby
# frozen_string_literal: true

# リポジトリパスは非ASCIIを含むため、filesystem encodingがUTF-8でないlocaleでは自分をUTF-8で再実行する
if Encoding.find("filesystem") != Encoding::UTF_8 && !ENV["HS_VALIDATOR_UTF8_REEXEC"]
  require "rbconfig"
  exec({ "LC_ALL" => "en_US.UTF-8", "HS_VALIDATOR_UTF8_REEXEC" => "1" }, RbConfig.ruby, __FILE__, *ARGV)
end

require "digest"
require "json"
require "pathname"

ROOT = Pathname.new(File.expand_path("..", __dir__))
CORE = ROOT.join("generated/rag/core")
MANIFEST_PATH = CORE.join("manifest.json")

errors = []

unless MANIFEST_PATH.file?
  warn "FAIL: missing #{MANIFEST_PATH}"
  exit 1
end

manifest = JSON.parse(MANIFEST_PATH.read(encoding: "UTF-8"))
entries = manifest.fetch("files")
declared = entries.map { |entry| entry.fetch("file") }.sort
actual = Dir.glob(CORE.join("*.md")).map do |path|
  Pathname.new(path).relative_path_from(ROOT).to_s
end.sort

errors << "manifest/file set mismatch" unless declared == actual
errors << "pack version must be 1.2.0" unless manifest["pack_version"] == "1.2.0"

entries.each do |entry|
  file = ROOT.join(entry.fetch("file"))
  source = ROOT.join(entry.fetch("source_path"))

  errors << "missing generated file: #{file}" unless file.file?
  errors << "missing source file: #{source}" unless source.file?
  next unless file.file? && source.file?

  errors << "generated hash mismatch: #{file}" unless Digest::SHA256.file(file).hexdigest == entry.fetch("sha256")
  errors << "source hash mismatch: #{source}" unless Digest::SHA256.file(source).hexdigest == entry.fetch("source_sha256")

  text = file.read(encoding: "UTF-8")
  errors << "missing generated marker: #{file}" unless text.include?("generated: true") && text.include?("do_not_edit: true")
  errors << "missing transformation marker: #{file}" unless text.include?("transformation: #{entry.fetch('transformation')}")
  errors << "note URL leaked: #{file}" if text.match?(%r{https?://note\.com/}i)
  errors << "withdrawn matter definition leaked: #{file}" if text.match?(/現のうち、?源則に律される部分(?:が|＝)物質/)
  errors << "withdrawn fire definition leaked: #{file}" if text.match?(/火\s*[＝=]\s*意識/)
  errors << "withdrawn coined term leaked: #{file}" if text.include?("信火")
  errors << "raw dialogue enabled: #{file}" if text.include?("public_raw_dialogue: true")
end

source_paths = entries.map { |entry| entry.fetch("source_path") }
%w[raw/ en/ zh-Hant/ docs/].each do |prefix|
  leaked = source_paths.select { |path| path.start_with?(prefix) }
  errors << "forbidden source prefix #{prefix}: #{leaked.join(', ')}" unless leaked.empty?
end

if errors.empty?
  puts "PASS: #{entries.length} core RAG document(s), hashes and exclusion rules verified"
else
  warn "FAIL: #{errors.length} RAG validation error(s)"
  errors.each { |error| warn "- #{error}" }
  exit 1
end
