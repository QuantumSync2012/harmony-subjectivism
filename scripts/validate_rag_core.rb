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
require_relative "lib/hs_release"

ROOT = Pathname.new(File.expand_path("..", __dir__))

# --dir <path> でstage等の検証対象rootを指定できる(既定=generated/rag)
rag_root = ROOT.join("generated/rag")
if (index = ARGV.index("--dir"))
  rag_root = Pathname.new(ARGV[index + 1] || abort("usage: validate_rag_core.rb [--dir <rag-root>]"))
  rag_root = ROOT.join(rag_root) if rag_root.relative?
end

CORE = rag_root.join("core")
MANIFEST_PATH = CORE.join("manifest.json")

errors = []

unless MANIFEST_PATH.file?
  warn "FAIL: missing #{MANIFEST_PATH}"
  exit 1
end

expected_version = HsRelease.registry_version

# --- version contract(統合修正仕様v1 §6): 版宣言の不一致はexit non-zero ---
version_sources = {
  "README current version" => [ROOT.join("README.md"), /\*\*現行版\*\*: v(\d+\.\d+\.\d+)/],
  "README Japanese canon version" => [ROOT.join("README.md"), /日本語正本.*?v(\d+\.\d+\.\d+)/],
  "canon/glossary internal version" => [ROOT.join("canon/glossary.md"), /版宣言.*?v(\d+\.\d+\.\d+)/],
  "canon/principles internal version" => [ROOT.join("canon/principles.md"), /—\s*調和的主観主義\s*v(\d+\.\d+\.\d+)/],
  "evaluation contract version" => [ROOT.join("research/rag-core-evaluation.md"), /\A# Core RAG受入質問 — v(\d+\.\d+\.\d+)/]
}
version_sources.each do |label, (path, pattern)|
  unless path.file?
    errors << "version source missing: #{label} (#{path})"
    next
  end
  match = path.read(encoding: "UTF-8").match(pattern)
  if match.nil?
    errors << "version declaration not found: #{label}"
  elsif match[1] != expected_version
    errors << "version mismatch: #{label} is v#{match[1]}, registry is v#{expected_version}"
  end
end

manifest = JSON.parse(MANIFEST_PATH.read(encoding: "UTF-8"))

%w[schema_version release_id pack pack_version collection_name source_commit generator_path generator_sha256 registry_sha256 built_at files].each do |key|
  errors << "manifest missing key: #{key}" unless manifest.key?(key)
end
errors << "manifest pack_version must be #{expected_version}" unless manifest["pack_version"] == expected_version
errors << "manifest release_id must embed v#{expected_version}" unless manifest["release_id"].to_s.include?("hs-v#{expected_version}+")

# 最新のbuild receiptが在ればその版も契約に含める(無ければ未発行としてskip)
latest_receipt = Dir.glob(ROOT.join("generated/receipts/*_build_*_pass.json")).max_by { |path| File.mtime(path) }
if latest_receipt
  receipt = JSON.parse(File.read(latest_receipt, encoding: "UTF-8"))
  errors << "release receipt version mismatch: #{receipt['pack_version']}" unless receipt["pack_version"] == expected_version
end

entries = manifest.fetch("files")
declared = entries.map { |entry| entry.fetch("file").sub("generated/rag/", "") }.sort
actual = Dir.glob(CORE.join("*.md")).map { |path| "core/#{File.basename(path)}" }.sort

errors << "manifest/file set mismatch" unless declared == actual

entries.each do |entry|
  file = rag_root.join(entry.fetch("file").sub("generated/rag/", ""))
  source = ROOT.join(entry.fetch("source_path"))

  errors << "missing generated file: #{file}" unless file.file?
  errors << "missing source file: #{source}" unless source.file?
  next unless file.file? && source.file?

  errors << "generated hash mismatch: #{file}" unless Digest::SHA256.file(file).hexdigest == entry.fetch("sha256")
  errors << "source hash mismatch: #{source}" unless Digest::SHA256.file(source).hexdigest == entry.fetch("source_sha256")

  text = file.read(encoding: "UTF-8")
  errors << "missing generated marker: #{file}" unless text.include?("generated: true") && text.include?("do_not_edit: true")
  errors << "missing transformation marker: #{file}" unless text.include?("transformation: #{entry.fetch('transformation')}")
  errors << "doc pack version mismatch: #{file}" unless text.include?("rag_pack_version: #{expected_version}")
  errors << "note URL leaked: #{file}" if text.match?(%r{https?://note\.com/}i)
  errors << "withdrawn matter definition leaked: #{file}" if text.match?(/現のうち、?源則に律される部分(?:が|＝)物質/)
  errors << "withdrawn fire definition leaked: #{file}" if text.match?(/火\s*[＝=]\s*意識/)
  errors << "withdrawn coined term leaked: #{file}" if text.include?("信火")
  errors << "raw dialogue enabled: #{file}" if text.include?("public_raw_dialogue: true")
  errors << "retired ledger leaked into core: #{file}" if text.include?("## 三、不採用・廃語台帳")
end

source_paths = entries.map { |entry| entry.fetch("source_path") }
%w[raw/ en/ zh-Hant/ docs/].each do |prefix|
  leaked = source_paths.select { |path| path.start_with?(prefix) }
  errors << "forbidden source prefix #{prefix}: #{leaked.join(', ')}" unless leaked.empty?
end

if errors.empty?
  puts "PASS: #{entries.length} core RAG document(s), version contract v#{expected_version}, hashes and exclusion rules verified"
else
  warn "FAIL: #{errors.length} RAG validation error(s)"
  errors.each { |error| warn "- #{error}" }
  exit 1
end
