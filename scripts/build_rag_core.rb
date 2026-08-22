#!/usr/bin/env ruby
# frozen_string_literal: true

# リポジトリパスは非ASCIIを含むため、filesystem encodingがUTF-8でないlocaleでは自分をUTF-8で再実行する
if Encoding.find("filesystem") != Encoding::UTF_8 && !ENV["HS_VALIDATOR_UTF8_REEXEC"]
  require "rbconfig"
  exec({ "LC_ALL" => "en_US.UTF-8", "HS_VALIDATOR_UTF8_REEXEC" => "1" }, RbConfig.ruby, __FILE__, *ARGV)
end

require "digest"
require "fileutils"
require "json"
require "pathname"
require "rbconfig"
require "time"
require_relative "lib/hs_release"

# 決定論build・atomic publish(統合修正仕様v1 §9):
#   1. 前提検査(quote sync・version)
#   2. sibling stage(generated/rag.stage/)へcurrent/retiredを全量生成
#   3. manifest・lexicon・fixtureをstage内で生成
#   4-7. current/retired validator・stale-output selftest・collisionをstageに対して実行
#   8. 全PASS後にdirectory単位でpublish(旧artifactはgenerated/rag.previous/へ保持)
#   9-10. receiptをgenerated/receipts/へ発行。失敗stageは削除せずrenameで保持
ROOT = Pathname.new(File.expand_path("..", __dir__))
PUBLISH_DIR = ROOT.join("generated/rag")
STAGE_DIR = ROOT.join("generated/rag.stage")
PREVIOUS_DIR = ROOT.join("generated/rag.previous")
RECEIPTS_DIR = ROOT.join("generated/receipts")
PACK_VERSION = HsRelease.pack_version
RELEASE_ID = HsRelease.release_id

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

RETIRED_LEDGER_PATTERN = /\n(## 三、不採用・廃語台帳\n.*?)(?=\n## |\z)/m

def prepare_for_rag(relative, text)
  prepared = strip_frontmatter(text)
  return prepared unless relative == "canon/glossary.md"

  prepared.sub(RETIRED_LEDGER_PATTERN, "\n")
end

# 廃語台帳は current pack に入れない(validate_rag_core が撤回語の混入を fail-closed で禁じている)。
# 「現行の答えとして返さない」を保ったまま「撤回された事実には到達できる」を両立させるため、
# 別スコープ retired/ へ出し、qmd では別コレクションとして索引する(2026-08-21、別collection化=2026-08-22仕様v1)。
def extract_retired_ledger(text)
  match = strip_frontmatter(text).match(RETIRED_LEDGER_PATTERN)
  match && match[1]
end

# 台帳表の行から語を引く。label=表記全体、bare=括弧注記を除いた検索語
def ledger_words(ledger_text)
  ledger_text.lines.map do |line|
    next unless line.start_with?("| ")
    next if line.start_with?("| 語 ")

    label = line.split("|")[1].to_s.strip.gsub(%r{<a id="[^"]*"></a>}, "").strip
    next if label.empty?

    { "label" => label, "bare" => label.sub(/[（(].*\z/, "").strip }
  end.compact
end

def retired_doc_header(source_sha)
  <<~YAML
    ---
    generated: true
    do_not_edit: true
    rag_pack: harmonious-subjectivism-retired
    rag_pack_version: #{PACK_VERSION}
    release_id: #{RELEASE_ID}
    authority: current_canon
    status: retired_ledger
    source_path: canon/glossary.md
    source_sha256: #{source_sha}
    transformation: retired_ledger_extracted
    ---

    > この文書は**撤回・不採用となった語の台帳**である。ここに載る語は現行の体系語ではない。
    > 「その語は撤回されたか」への回答根拠であり、現行の定義として引用してはならない。

  YAML
end

STATUS_WORDS = %w[撤回 不採用 廃語].freeze

def fixture_cases(words)
  cases = []
  words.each do |word|
    bare = word.fetch("bare")
    base_gate = {
      "must_include_any" => STATUS_WORDS,
      "must_not_patterns" => ["#{bare}とは.+である(?!.*(撤回|不採用|廃語))"]
    }
    cases << { "word" => bare, "intent" => "explain_old",
               "query" => "「#{bare}」というかつての語の説明", "expected_scope" => "retired",
               "answer_gate" => base_gate }
    cases << { "word" => bare, "intent" => "is_current",
               "query" => "「#{bare}」は現行の体系語か", "expected_scope" => "retired",
               "answer_gate" => base_gate }
    cases << { "word" => bare, "intent" => "diff_from_current",
               "query" => "「#{bare}」と現行の体系語との違い", "expected_scope" => "retired",
               "answer_gate" => base_gate }
    # current質問へのretired語混入(collision): defaultはcurrentが答え、retiredが順位を奪わない
    cases << { "word" => bare, "intent" => "collision_mixed",
               "query" => "#{bare}という言葉を使わずに、対応する現行の考え方を説明して", "expected_scope" => "current_priority",
               "answer_gate" => { "must_not_patterns" => ["#{bare}とは.+である(?!.*(撤回|不採用|廃語))"] } }
  end
  cases
end

def build_stage!(stage)
  FileUtils.rm_rf(stage)
  current_dir = stage.join("core")
  retired_dir = stage.join("retired")
  FileUtils.mkdir_p(current_dir)
  FileUtils.mkdir_p(retired_dir)

  generator_sha = Digest::SHA256.file(__FILE__).hexdigest
  built_at = Time.now.strftime("%Y-%m-%dT%H:%M:%S%:z")
  retired_outputs = []
  glossary_sha = nil
  ledger = nil

  entries = sources.map do |source|
    raise "missing source: #{source}" unless source.file?

    relative = source.relative_path_from(ROOT).to_s
    source_text = source.read(encoding: "UTF-8")
    rag_text = prepare_for_rag(relative, source_text)

    if FORBIDDEN_SOURCE_PREFIXES.any? { |prefix| relative.start_with?(prefix) }
      raise "forbidden source path: #{relative}"
    end
    FORBIDDEN_CONTENT.each do |label, pattern|
      raise "#{label} in #{relative}" if rag_text.match?(pattern)
    end
    raise "raw dialogue marked public in #{relative}" if rag_text.include?("public_raw_dialogue: true")

    source_sha = Digest::SHA256.hexdigest(source_text)
    if relative == "canon/glossary.md"
      glossary_sha = source_sha
      ledger = extract_retired_ledger(source_text)
    end

    target = current_dir.join(output_name(relative))
    transformation = relative == "canon/glossary.md" ? "retired_ledger_excluded" : "frontmatter_removed"
    metadata = <<~YAML
      ---
      generated: true
      do_not_edit: true
      rag_pack: harmonious-subjectivism-core
      rag_pack_version: #{PACK_VERSION}
      release_id: #{RELEASE_ID}
      authority: #{authority_for(relative)}
      status: #{status_for(relative)}
      source_path: #{relative}
      source_sha256: #{source_sha}
      transformation: #{transformation}
      ---

    YAML
    target.write(metadata + rag_text, encoding: "UTF-8")

    {
      "file" => "generated/rag/core/#{target.basename}",
      "sha256" => Digest::SHA256.file(target).hexdigest,
      "source_path" => relative,
      "source_sha256" => source_sha,
      "transformation" => transformation,
      "authority" => authority_for(relative),
      "status" => status_for(relative)
    }
  end

  raise "retired ledger section not found in canon/glossary.md" unless ledger

  # retired: 台帳doc + lexicon + 動的fixture(台帳全行から機械列挙・語数を恒久定数にしない)
  ledger_doc = retired_dir.join("canon__glossary__retired-ledger.md")
  ledger_doc.write(retired_doc_header(glossary_sha) + ledger + "\n", encoding: "UTF-8")
  words = ledger_words(ledger)
  raise "retired ledger has no word rows" if words.empty?

  lexicon = {
    "schema_version" => 1, "release_id" => RELEASE_ID,
    "source_path" => "canon/glossary.md", "source_sha256" => glossary_sha,
    "words" => words
  }
  lexicon_path = retired_dir.join("retired-lexicon.json")
  lexicon_path.write(JSON.pretty_generate(lexicon) + "\n", encoding: "UTF-8")

  fixture = {
    "schema_version" => 1, "release_id" => RELEASE_ID,
    "source_sha256" => glossary_sha, "generated_at" => built_at,
    "word_count" => words.length,
    "status_words" => STATUS_WORDS,
    "cases" => fixture_cases(words)
  }
  fixture_path = retired_dir.join("retired-fixture.json")
  fixture_path.write(JSON.pretty_generate(fixture) + "\n", encoding: "UTF-8")

  [ledger_doc, lexicon_path, fixture_path].each do |path|
    retired_outputs << {
      "file" => "generated/rag/retired/#{path.basename}",
      "sha256" => Digest::SHA256.file(path).hexdigest,
      "source_path" => "canon/glossary.md",
      "source_sha256" => glossary_sha
    }
  end

  manifest_common = {
    "schema_version" => 1,
    "release_id" => RELEASE_ID,
    "pack_version" => PACK_VERSION,
    "language" => "ja",
    "source_commit" => HsRelease.source_commit,
    "source_dirty" => HsRelease.source_dirty?,
    "generator_path" => "scripts/build_rag_core.rb",
    "generator_sha256" => generator_sha,
    "registry_sha256" => HsRelease.registry_sha256,
    "built_at" => built_at
  }

  current_manifest = manifest_common.merge(
    "pack" => "harmonious-subjectivism-core",
    "collection_name" => "harmonious-subjectivism-current",
    "authority" => "current_canon",
    "scope" => "current Japanese canon-checked public explanations",
    "excluded" => [
      "raw dialogue",
      "dictionary raw transcription",
      "historical translations",
      "v0.1.1 publication tree",
      "retired or rejected definitions as current answers"
    ],
    "files" => entries
  )
  current_dir.join("manifest.json").write(JSON.pretty_generate(current_manifest) + "\n", encoding: "UTF-8")

  retired_manifest = manifest_common.merge(
    "pack" => "harmonious-subjectivism-retired",
    "collection_name" => "harmonious-subjectivism-retired",
    "authority" => "current_canon",
    "status" => "retired_ledger",
    "scope" => "retired and rejected terms as status evidence, never as current definitions",
    "word_count" => words.length,
    "fixture_sha256" => Digest::SHA256.file(fixture_path).hexdigest,
    "lexicon_sha256" => Digest::SHA256.file(lexicon_path).hexdigest,
    "files" => retired_outputs
  )
  retired_dir.join("manifest.json").write(JSON.pretty_generate(retired_manifest) + "\n", encoding: "UTF-8")

  entries.length + retired_outputs.length
end

def run_step!(label, *command)
  puts "-- #{label}"
  return if system(*command, chdir: ROOT.to_s)

  raise "step failed: #{label}"
end

def write_receipt!(status, error: nil)
  RECEIPTS_DIR.mkpath
  stamp = Time.now.strftime("%Y%m%dT%H%M%S")
  receipt = {
    "schema_version" => 1,
    "release_id" => RELEASE_ID,
    "pack_version" => PACK_VERSION,
    "status" => status,
    "source_commit" => HsRelease.source_commit,
    "source_dirty" => HsRelease.source_dirty?,
    "built_at" => Time.now.strftime("%Y-%m-%dT%H:%M:%S%:z"),
    "published_path" => "generated/rag",
    "previous_path" => PREVIOUS_DIR.exist? ? "generated/rag.previous" : nil,
    "error" => error
  }
  path = RECEIPTS_DIR.join("#{RELEASE_ID.gsub('+', '_')}_build_#{stamp}_#{status}.json")
  path.write(JSON.pretty_generate(receipt) + "\n", encoding: "UTF-8")
  puts "Receipt: #{path}"
end

begin
  # 1. 前提検査
  run_step!("canonical definition quote check",
            RbConfig.ruby, ROOT.join("scripts/sync_definition_quotes.rb").to_s, "--check")

  # 2-3. stageへ全量生成
  total = build_stage!(STAGE_DIR)
  puts "-- staged #{total} artifact(s) in #{STAGE_DIR}"

  # 4-6. stageに対する検証(current・retired・stale-output selftest)
  run_step!("current pack validation (stage)",
            RbConfig.ruby, ROOT.join("scripts/validate_rag_core.rb").to_s, "--dir", STAGE_DIR.to_s)
  run_step!("retired pack validation (stage)",
            RbConfig.ruby, ROOT.join("scripts/validate_rag_retired.rb").to_s, "--dir", STAGE_DIR.to_s)
  run_step!("stale-output rejection selftest",
            RbConfig.ruby, ROOT.join("scripts/validate_rag_retired.rb").to_s, "--selftest")

  # 8. atomic publish(directory単位・旧artifactはrollback用に保持)
  FileUtils.rm_rf(PREVIOUS_DIR)
  FileUtils.mv(PUBLISH_DIR, PREVIOUS_DIR) if PUBLISH_DIR.exist?
  FileUtils.mv(STAGE_DIR, PUBLISH_DIR)

  # publish後の最終検証(公開位置でもPASSすることを確認)
  run_step!("current pack validation (published)",
            RbConfig.ruby, ROOT.join("scripts/validate_rag_core.rb").to_s)
  run_step!("retired pack validation (published)",
            RbConfig.ruby, ROOT.join("scripts/validate_rag_retired.rb").to_s)

  # 9-10. receipt発行
  write_receipt!("pass")
  puts "Built and published #{RELEASE_ID} to #{PUBLISH_DIR}"
rescue StandardError => e
  # 失敗stageは削除せず保持(統合修正仕様v1 §9)。公開中artifactは変更しない。
  if STAGE_DIR.exist?
    failed = ROOT.join("generated/rag.stage.failed-#{Time.now.strftime('%Y%m%dT%H%M%S')}")
    FileUtils.mv(STAGE_DIR, failed)
    warn "failed stage preserved: #{failed}"
  end
  write_receipt!("fail", error: e.message)
  abort "FAIL: #{e.message}"
end
