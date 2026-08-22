#!/usr/bin/env ruby
# frozen_string_literal: true

# リポジトリパスは非ASCIIを含むため、filesystem encodingがUTF-8でないlocaleでは自分をUTF-8で再実行する
if Encoding.find("filesystem") != Encoding::UTF_8 && !ENV["HS_VALIDATOR_UTF8_REEXEC"]
  require "rbconfig"
  exec({ "LC_ALL" => "en_US.UTF-8", "HS_VALIDATOR_UTF8_REEXEC" => "1" }, RbConfig.ruby, __FILE__, *ARGV)
end

require "json"
require "pathname"

# 決定論意味gate(統合修正仕様v1 §12)。LLM回答の受入を機械判定する主gate。
# 入力: JSON配列 [{"word": 語, "scope": "retired"|"current", "answer": 回答本文}, ...]
# 判定:
#   retired scope: 回答に撤回/不採用/廃語のいずれかが必須。
#   全scope: status語なしの「<語>とは…である」型の現行定義文を禁止(retired語について)。
#   全scope: registryに無いstable ID(HS-C-xxxx)の引用を禁止。
# exit 0=PASS / 1=違反あり / 2=入力不正
ROOT = Pathname.new(File.expand_path("..", __dir__))
STATUS_PATTERN = /撤回|不採用|廃語/

input = ARGV.reject { |arg| arg.start_with?("--") }.first
abort_usage = lambda do
  warn "usage: check_answer_semantics.rb <answers.json>"
  exit 2
end
abort_usage.call unless input

path = Pathname.new(input)
path = ROOT.join(path) if path.relative?
abort_usage.call unless path.file?

begin
  answers = JSON.parse(path.read(encoding: "UTF-8"))
rescue JSON::ParserError => e
  warn "invalid JSON: #{e.message}"
  exit 2
end

registry_ids = ROOT.join("research/hs-id-registry.yaml")
                   .read(encoding: "UTF-8")
                   .scan(/HS-C-\d{4}/i)
                   .map(&:upcase)
                   .uniq

violations = []
answers.each_with_index do |entry, index|
  word = entry["word"].to_s
  scope = entry["scope"].to_s
  answer = entry["answer"].to_s
  label = "answer[#{index}] (#{word})"

  if answer.strip.empty?
    violations << "#{label}: empty answer"
    next
  end

  has_status = answer.match?(STATUS_PATTERN)

  violations << "#{label}: retired answer lacks status word (撤回/不採用/廃語)" if scope == "retired" && !has_status

  if !word.empty? && answer.match?(/#{Regexp.escape(word)}とは.+である/) && !has_status
    violations << "#{label}: presents retired term as current definition without status word"
  end

  answer.scan(/HS-C-\d{4}/i).map(&:upcase).uniq.each do |cited|
    violations << "#{label}: unsupported stable ID #{cited}" unless registry_ids.include?(cited)
  end
end

if violations.empty?
  puts "PASS: #{answers.length} answer(s) passed the deterministic semantic gate"
else
  warn "FAIL: #{violations.length} semantic violation(s)"
  violations.each { |violation| warn "- #{violation}" }
  exit 1
end
