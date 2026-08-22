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
require "tmpdir"
require_relative "lib/hs_release"

# retired pack validator(統合修正仕様v1 §7・§9・§12):
# - 台帳doc・lexicon・fixture・manifestが同一のcanon/glossary.md source SHA-256へ束縛されていること
# - sourceの台帳節が消えた場合、残存するretired artifactを拒否すること(stale-output rejection)
# - 台帳行数・lexicon語数・fixture語数の一致(語数を恒久定数にしない)
# - retired回答契約のstatus語がfixtureに含まれること
ROOT = Pathname.new(File.expand_path("..", __dir__))
LEDGER_SECTION = "## 三、不採用・廃語台帳"

def ledger_section_of(glossary_text)
  stripped = glossary_text.sub(/\A---\n.*?\n---\n/m, "")
  match = stripped.match(/\n(#{Regexp.escape(LEDGER_SECTION)}\n.*?)(?=\n## |\z)/m)
  match && match[1]
end

def ledger_row_count(section)
  section.lines.count { |line| line.start_with?("| ") && !line.start_with?("| 語 ") }
end

# rag_root/retired をglossaryに対して検証し、エラー配列を返す
def validate_retired(rag_root, glossary_path)
  errors = []
  retired = rag_root.join("retired")
  manifest_path = retired.join("manifest.json")
  ledger_doc = retired.join("canon__glossary__retired-ledger.md")
  lexicon_path = retired.join("retired-lexicon.json")
  fixture_path = retired.join("retired-fixture.json")

  unless glossary_path.file?
    return ["missing source: #{glossary_path}"]
  end

  glossary_text = glossary_path.read(encoding: "UTF-8")
  glossary_sha = Digest::SHA256.hexdigest(glossary_text)
  section = ledger_section_of(glossary_text)

  artifacts_present = [manifest_path, ledger_doc, lexicon_path, fixture_path].select(&:file?)

  # stale-output rejection: source側に台帳節が無いのにretired artifactが残っていたら拒否
  if section.nil?
    unless artifacts_present.empty?
      errors << "stale retired artifact(s): source has no ledger section but #{artifacts_present.length} artifact(s) remain"
    end
    return errors
  end

  { "manifest" => manifest_path, "ledger doc" => ledger_doc,
    "lexicon" => lexicon_path, "fixture" => fixture_path }.each do |label, path|
    errors << "missing retired #{label}: #{path}" unless path.file?
  end
  return errors unless errors.empty?

  manifest = JSON.parse(manifest_path.read(encoding: "UTF-8"))
  lexicon = JSON.parse(lexicon_path.read(encoding: "UTF-8"))
  fixture = JSON.parse(fixture_path.read(encoding: "UTF-8"))
  doc_text = ledger_doc.read(encoding: "UTF-8")

  expected_version = HsRelease.registry_version
  %w[schema_version release_id pack pack_version collection_name source_commit generator_sha256 registry_sha256 built_at word_count fixture_sha256 lexicon_sha256 files].each do |key|
    errors << "retired manifest missing key: #{key}" unless manifest.key?(key)
  end
  errors << "retired manifest pack_version must be #{expected_version}" unless manifest["pack_version"] == expected_version
  errors << "retired doc pack version mismatch" unless doc_text.include?("rag_pack_version: #{expected_version}")

  # source束縛: doc・lexicon・fixture・manifest entriesがすべて現glossary SHAと一致(=鮮度保証)
  doc_sha_line = doc_text[/source_sha256: (\h{64})/, 1]
  errors << "ledger doc source_sha256 stale (doc=#{doc_sha_line&.slice(0, 12)} live=#{glossary_sha[0, 12]})" unless doc_sha_line == glossary_sha
  errors << "lexicon source_sha256 stale" unless lexicon["source_sha256"] == glossary_sha
  errors << "fixture source_sha256 stale" unless fixture["source_sha256"] == glossary_sha
  manifest.fetch("files", []).each do |entry|
    errors << "manifest entry source_sha256 stale: #{entry['file']}" unless entry["source_sha256"] == glossary_sha
  end

  # 出力hash整合
  manifest.fetch("files", []).each do |entry|
    file = rag_root.join(entry.fetch("file").sub("generated/rag/", ""))
    if file.file?
      errors << "retired output hash mismatch: #{file}" unless Digest::SHA256.file(file).hexdigest == entry.fetch("sha256")
    else
      errors << "missing retired output: #{file}"
    end
  end
  errors << "fixture_sha256 mismatch" unless manifest["fixture_sha256"] == Digest::SHA256.file(fixture_path).hexdigest
  errors << "lexicon_sha256 mismatch" unless manifest["lexicon_sha256"] == Digest::SHA256.file(lexicon_path).hexdigest

  # 語数整合: 台帳行数 == lexicon == fixture(恒久定数を持たない)
  rows = ledger_row_count(section)
  errors << "ledger has no word rows" if rows.zero?
  errors << "lexicon word count #{lexicon['words']&.length} != ledger rows #{rows}" unless lexicon["words"]&.length == rows
  errors << "fixture word_count #{fixture['word_count']} != ledger rows #{rows}" unless fixture["word_count"] == rows
  errors << "manifest word_count #{manifest['word_count']} != ledger rows #{rows}" unless manifest["word_count"] == rows
  fixture_words = fixture.fetch("cases", []).map { |c| c["word"] }.uniq
  errors << "fixture cases cover #{fixture_words.length} word(s), expected #{rows}" unless fixture_words.length == rows

  # 回答契約: status語(撤回/不採用/廃語)がfixtureのgateに宣言されていること
  errors << "fixture status_words must include 撤回/不採用/廃語" unless (%w[撤回 不採用 廃語] - fixture.fetch("status_words", [])).empty?

  # 台帳docは「現行定義として引用してはならない」注意書きを保持すること
  errors << "ledger doc missing usage warning" unless doc_text.include?("現行の定義として引用してはならない")

  errors
end

# --selftest: stale-output拒否と正常系を合成dirで検証(非LLM・exit判定・固定文字列に依存しない)
def selftest!
  failures = []
  Dir.mktmpdir("hs-retired-selftest") do |tmp|
    tmp = Pathname.new(tmp)
    glossary = tmp.join("glossary.md")
    rag_root = tmp.join("rag")
    retired = rag_root.join("retired")
    retired.mkpath

    # case 1: source台帳節なし + artifact残存 → 拒否されるべき
    glossary.write("# 用語集\n\n## 一、定義\n\n本文\n", encoding: "UTF-8")
    retired.join("canon__glossary__retired-ledger.md").write("stale", encoding: "UTF-8")
    errors = validate_retired(rag_root, glossary)
    failures << "case1: stale artifact was not rejected" if errors.empty?

    # case 2: source台帳節なし + artifactなし → PASSすべき
    retired.join("canon__glossary__retired-ledger.md").delete
    errors = validate_retired(rag_root, glossary)
    failures << "case2: empty state rejected: #{errors.join('; ')}" unless errors.empty?

    # case 3: 台帳節あり + artifact欠落 → 拒否されるべき
    glossary.write("# 用語集\n\n## 三、不採用・廃語台帳\n\n| 語 | 理由 |\n|---|---|\n| 試語 | 試験 |\n", encoding: "UTF-8")
    errors = validate_retired(rag_root, glossary)
    failures << "case3: missing artifacts were not rejected" if errors.empty?

    # case 4: 台帳節あり + 古いsource_sha256のdoc → 拒否されるべき
    retired.join("manifest.json").write(JSON.generate({ "files" => [] }), encoding: "UTF-8")
    retired.join("canon__glossary__retired-ledger.md").write("---\nsource_sha256: #{'0' * 64}\n---\n", encoding: "UTF-8")
    retired.join("retired-lexicon.json").write(JSON.generate({ "source_sha256" => "0" * 64, "words" => [] }), encoding: "UTF-8")
    retired.join("retired-fixture.json").write(JSON.generate({ "source_sha256" => "0" * 64, "cases" => [] }), encoding: "UTF-8")
    errors = validate_retired(rag_root, glossary)
    failures << "case4: stale source_sha256 was not rejected" if errors.none? { |e| e.include?("stale") }
  end

  if failures.empty?
    puts "SELFTEST PASS: 4 case(s)"
    exit 0
  else
    warn "SELFTEST FAIL:"
    failures.each { |f| warn "- #{f}" }
    exit 1
  end
end

if ARGV.include?("--selftest")
  selftest!
end

rag_root = ROOT.join("generated/rag")
if (index = ARGV.index("--dir"))
  rag_root = Pathname.new(ARGV[index + 1] || abort("usage: validate_rag_retired.rb [--dir <rag-root>] [--selftest]"))
  rag_root = ROOT.join(rag_root) if rag_root.relative?
end

errors = validate_retired(rag_root, ROOT.join("canon/glossary.md"))

if errors.empty?
  ledger_rows = ledger_row_count(ledger_section_of(ROOT.join("canon/glossary.md").read(encoding: "UTF-8")).to_s)
  puts "PASS: retired pack verified (#{ledger_rows} ledger word(s), source-bound, stale-output rejection active)"
else
  warn "FAIL: #{errors.length} retired validation error(s)"
  errors.each { |error| warn "- #{error}" }
  exit 1
end
