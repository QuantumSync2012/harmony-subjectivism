#!/usr/bin/env ruby
# frozen_string_literal: true

# リポジトリパスは非ASCIIを含むため、filesystem encodingがUTF-8でないlocaleでは自分をUTF-8で再実行する
if Encoding.find("filesystem") != Encoding::UTF_8 && !ENV["HS_VALIDATOR_UTF8_REEXEC"]
  require "rbconfig"
  exec({ "LC_ALL" => "en_US.UTF-8", "HS_VALIDATOR_UTF8_REEXEC" => "1" }, RbConfig.ruby, __FILE__, *ARGV)
end

require "json"
require "pathname"

# 決定論意味gate(統合修正仕様v1 §12・CF NO-GO P1-5対応)。LLM回答の受入を機械判定する主gate。
#
# 使い方:
#   check_answer_semantics.rb <answers.json> --fixture <retired-fixture.json>
#   check_answer_semantics.rb <answers.json> --regression <retired_regression_*.json>
#
# fixture mode: answers = [{"case_id": "<語:意図>", "answer": "..."}]
#   - fixtureの全caseがexactly once提出されることを要求(欠落・重複・fixture外idを拒否)
#   - scope/word/gateはfixture側から導出する(回答側でのscope偽装を排除)
# regression mode: answers = [{"word": "<旧語>", "answer": "..."}]
#   - regression fixtureの全語がexactly once提出されることを要求
#
# 判定(全modeでdeterministic・非LLM・exit code準拠):
#   - retired scope: 撤回/不採用/廃語のいずれかが必須
#   - status否定(「廃語ではない」「撤回されていない」等)を拒否
#   - 「<語>とは…である」型の現行定義文の復活を拒否(改行・空白を跨いで検査)
#   - registryに無いstable ID(HS-C-xxxx)の引用を拒否
# exit 0=PASS / 1=違反あり / 2=入力不正
ROOT = Pathname.new(File.expand_path("..", __dir__))
STATUS_PATTERN = /撤回|不採用|廃語/
# status語の否定形。「〜ではない/されていない/ではなく」等は撤回の事実の否認として拒否する
NEGATION_PATTERN = /(撤回|不採用|廃語)(?:語)?(?:ではない|でない|ではなかった|でなかった|されていない|されてない|されなかった|されておらず|ではなく|とされていない)/

def registry_ids
  @registry_ids ||= ROOT.join("research/hs-id-registry.yaml")
                        .read(encoding: "UTF-8")
                        .scan(/HS-C-\d{4}/i)
                        .map(&:upcase)
                        .uniq
end

def definition_revival?(word, answer)
  return false if word.to_s.empty?

  # 改行・空白・強調記号を跨いだ「<語>とは…である/であり」を検査(P1-5: 表記差対応)
  answer.match?(/#{Regexp.escape(word)}[\s\*]*とは[\s\S]{0,160}?であ(?:る|り)/)
end

def answer_violations(label, word, scope, answer)
  violations = []
  if answer.strip.empty?
    violations << "#{label}: empty answer"
    return violations
  end

  negated = answer.match?(NEGATION_PATTERN)
  has_status = answer.match?(STATUS_PATTERN)

  if scope == "retired"
    violations << "#{label}: retired answer lacks status word (撤回/不採用/廃語)" unless has_status
    violations << "#{label}: denies retirement status (negated status word)" if negated
    violations << "#{label}: reintroduces retired term as current definition" if definition_revival?(word, answer)
  else
    violations << "#{label}: denies retirement status (negated status word)" if negated
    violations << "#{label}: reintroduces retired term as current definition" if definition_revival?(word, answer) && !has_status
  end

  answer.scan(/HS-C-\d{4}/i).map(&:upcase).uniq.each do |cited|
    violations << "#{label}: unsupported stable ID #{cited}" unless registry_ids.include?(cited)
  end
  violations
end

# fixture束縛(P1-5): 全caseがexactly once提出されることを検査
def fixture_mode_violations(answers, fixture)
  violations = []
  cases = fixture.fetch("cases", [])
  case_by_id = {}
  cases.each { |c| case_by_id[c.fetch("id")] = c }

  unless answers.is_a?(Array)
    return ["answers must be a JSON array"]
  end

  seen = Hash.new(0)
  answers.each_with_index do |entry, index|
    case_id = entry["case_id"].to_s
    if case_id.empty?
      violations << "answer[#{index}]: missing case_id"
      next
    end
    fixture_case = case_by_id[case_id]
    if fixture_case.nil?
      violations << "answer[#{index}]: unknown case_id #{case_id} (not in fixture)"
      next
    end
    seen[case_id] += 1
    scope = fixture_case.fetch("expected_scope") == "retired" ? "retired" : "current"
    violations.concat(answer_violations("#{case_id}", fixture_case.fetch("word"), scope, entry["answer"].to_s))
  end

  seen.each do |case_id, count|
    violations << "duplicate answers for case #{case_id} (#{count})" if count > 1
  end
  missing = case_by_id.keys - seen.keys
  violations << "missing answers for #{missing.length} fixture case(s): #{missing.first(5).join(', ')}#{missing.length > 5 ? ', …' : ''}" unless missing.empty?
  violations
end

def regression_mode_violations(answers, regression)
  violations = []
  words = regression.fetch("words", [])
  seen = Hash.new(0)
  answers.each_with_index do |entry, index|
    word = entry["word"].to_s
    if word.empty? || !words.include?(word)
      violations << "answer[#{index}]: word not in regression fixture: #{word.inspect}"
      next
    end
    seen[word] += 1
    bare = word.sub(/[（(].*\z/, "").strip
    violations.concat(answer_violations(word, bare, "retired", entry["answer"].to_s))
  end
  seen.each { |word, count| violations << "duplicate answers for #{word} (#{count})" if count > 1 }
  missing = words - seen.keys
  violations << "missing answers for #{missing.length} regression word(s): #{missing.first(5).join(', ')}#{missing.length > 5 ? ', …' : ''}" unless missing.empty?
  violations
end

# --selftest: 束縛と否定検出の負例を合成データで検証
def selftest!
  failures = []
  fixture = {
    "cases" => [
      { "id" => "自由:is_current", "word" => "自由", "intent" => "is_current", "expected_scope" => "retired" },
      { "id" => "自由:collision_mixed", "word" => "自由", "intent" => "collision_mixed", "expected_scope" => "current_priority" }
    ]
  }

  # case 1: 全件・正答 → PASS
  ok = [
    { "case_id" => "自由:is_current", "answer" => "自由は廃語であり、現行では自在を用いる。" },
    { "case_id" => "自由:collision_mixed", "answer" => "現行では自在という語で、縁起の中で自らを起点として在ることを扱う。" }
  ]
  failures << "case1: clean full submission rejected" unless fixture_mode_violations(ok, fixture).empty?

  # case 2: 1件だけ提出 → 欠落として拒否(P1-5)
  partial = [ok.first]
  failures << "case2: partial submission accepted" unless fixture_mode_violations(partial, fixture).any? { |v| v.include?("missing answers") }

  # case 3: status否定+旧定義復活 → 拒否(P1-5の実negative)
  bad = [
    { "case_id" => "自由:is_current", "answer" => "自由は廃語ではない。自由とは無条件に選べることである。" },
    ok.last
  ]
  violations = fixture_mode_violations(bad, fixture)
  failures << "case3: negated status accepted" unless violations.any? { |v| v.include?("denies retirement") }
  failures << "case3: definition revival accepted" unless violations.any? { |v| v.include?("reintroduces") }

  # case 4: fixture外id・重複 → 拒否
  weird = [ok.first, ok.first, { "case_id" => "偽:case", "answer" => "x" }]
  violations = fixture_mode_violations(weird, fixture)
  failures << "case4: duplicate not detected" unless violations.any? { |v| v.include?("duplicate") }
  failures << "case4: unknown case_id not detected" unless violations.any? { |v| v.include?("unknown case_id") }
  failures << "case4: missing not detected" unless violations.any? { |v| v.include?("missing answers") }

  # case 5: 未登録stable ID → 拒否
  fake_id = [
    { "case_id" => "自由:is_current", "answer" => "自由は廃語(HS-C-9999)。" },
    ok.last
  ]
  failures << "case5: unsupported ID accepted" unless fixture_mode_violations(fake_id, fixture).any? { |v| v.include?("unsupported stable ID") }

  if failures.empty?
    puts "SELFTEST PASS: 5 case(s)"
    exit 0
  else
    warn "SELFTEST FAIL:"
    failures.each { |f| warn "- #{f}" }
    exit 1
  end
end

selftest! if ARGV.include?("--selftest")

positional = ARGV.reject { |arg| arg.start_with?("--") }
fixture_arg = ARGV.index("--fixture") && ARGV[ARGV.index("--fixture") + 1]
regression_arg = ARGV.index("--regression") && ARGV[ARGV.index("--regression") + 1]
answers_arg = positional.first

unless answers_arg && (fixture_arg || regression_arg)
  warn "usage: check_answer_semantics.rb <answers.json> --fixture <fixture.json> | --regression <regression.json> | --selftest"
  exit 2
end

def load_json(arg)
  path = Pathname.new(arg)
  path = ROOT.join(path) if path.relative?
  unless path.file?
    warn "missing file: #{path}"
    exit 2
  end
  JSON.parse(path.read(encoding: "UTF-8"))
rescue JSON::ParserError => e
  warn "invalid JSON in #{arg}: #{e.message}"
  exit 2
end

answers = load_json(answers_arg)
violations =
  if fixture_arg
    fixture_mode_violations(answers, load_json(fixture_arg))
  else
    regression_mode_violations(answers, load_json(regression_arg))
  end

if violations.empty?
  puts "PASS: #{answers.length} answer(s) passed the deterministic semantic gate (full coverage)"
else
  warn "FAIL: #{violations.length} semantic violation(s)"
  violations.each { |violation| warn "- #{violation}" }
  exit 1
end
