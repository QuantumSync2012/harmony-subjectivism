#!/usr/bin/env ruby
# frozen_string_literal: true

# リポジトリパスは非ASCIIを含むため、filesystem encodingがUTF-8でないlocaleでは自分をUTF-8で再実行する
if Encoding.find("filesystem") != Encoding::UTF_8 && !ENV["HS_VALIDATOR_UTF8_REEXEC"]
  require "rbconfig"
  exec({ "LC_ALL" => "en_US.UTF-8", "HS_VALIDATOR_UTF8_REEXEC" => "1" }, RbConfig.ruby, __FILE__, *ARGV)
end

require "json"
require "pathname"
require "tmpdir"
require_relative "lib/hs_release"

# release receipt専用validator(CF NO-GO P1-6対応)。
# stage/pack validatorから分離し、exact release IDで照合する。
# historical receipt(過去版・失敗receipt)はprovenance記録として保持したまま、
# 現在版のbuildと検証を一切阻害しない。
#
# 使い方:
#   validate_release_receipt.rb <receipt.json>   … 指定receiptを現在のHEAD/registryへ照合
#   validate_release_receipt.rb --latest         … 現release IDに一致する最新receiptを照合
ROOT = Pathname.new(File.expand_path("..", __dir__))
RECEIPTS_DIR = ROOT.join("generated/receipts")

def receipt_errors(receipt, live_release_id, live_version, live_commit)
  errors = []
  errors << "receipt schema_version must be 1" unless receipt["schema_version"] == 1
  errors << "receipt status must be pass (got #{receipt['status']})" unless receipt["status"] == "pass"
  errors << "receipt release_id #{receipt['release_id']} != #{live_release_id}" unless receipt["release_id"] == live_release_id
  errors << "receipt pack_version #{receipt['pack_version']} != registry #{live_version}" unless receipt["pack_version"] == live_version
  errors << "receipt source_commit != HEAD" unless receipt["source_commit"] == live_commit
  errors
end

# 現release IDに一致するreceiptだけを対象にする(過去版receiptは無視=P1-6)
def latest_receipt_for(release_id)
  prefix = release_id.gsub("+", "_")
  Dir.glob(RECEIPTS_DIR.join("#{prefix}_build_*_pass.json")).max_by { |path| File.mtime(path) }
end

# --selftest: historical receiptが現在版の照合を阻害しないことを合成データで検証
def selftest!
  failures = []
  live_id = HsRelease.release_id
  live_version = HsRelease.registry_version
  live_commit = HsRelease.source_commit

  good = { "schema_version" => 1, "status" => "pass", "release_id" => live_id,
           "pack_version" => live_version, "source_commit" => live_commit }
  failures << "case1: valid receipt rejected" unless receipt_errors(good, live_id, live_version, live_commit).empty?

  old = good.merge("release_id" => "hs-v1.2.1+0000000", "pack_version" => "1.2.1")
  failures << "case2: historical receipt accepted as current" if receipt_errors(old, live_id, live_version, live_commit).empty?

  # case3: 過去版receiptがglob選択に混ざらないこと(prefixがrelease IDで絞られる)
  Dir.mktmpdir("hs-receipt-selftest") do |tmp|
    tmp = Pathname.new(tmp)
    tmp.join("hs-v1.2.1_0000000_build_20990101T000000_pass.json").write("{}", encoding: "UTF-8")
    tmp.join("#{live_id.gsub('+', '_')}_build_20990101T000001_pass.json").write("{}", encoding: "UTF-8")
    prefix = live_id.gsub("+", "_")
    picked = Dir.glob(tmp.join("#{prefix}_build_*_pass.json"))
    failures << "case3: selection not scoped to current release id" unless picked.length == 1 && picked.first.include?(prefix)
  end

  failures << "case4: forged status accepted" if receipt_errors(good.merge("status" => "fail"), live_id, live_version, live_commit).empty?

  if failures.empty?
    puts "SELFTEST PASS: 4 case(s)"
    exit 0
  else
    warn "SELFTEST FAIL:"
    failures.each { |f| warn "- #{f}" }
    exit 1
  end
end

selftest! if ARGV.include?("--selftest")

live_id = HsRelease.release_id
live_version = HsRelease.registry_version
live_commit = HsRelease.source_commit

receipt_path =
  if ARGV.include?("--latest")
    found = latest_receipt_for(live_id)
    unless found
      warn "FAIL: no pass receipt found for #{live_id} (historical receipts are ignored by design)"
      exit 1
    end
    Pathname.new(found)
  else
    arg = ARGV.reject { |a| a.start_with?("--") }.first
    unless arg
      warn "usage: validate_release_receipt.rb <receipt.json> | --latest | --selftest"
      exit 2
    end
    path = Pathname.new(arg)
    path.relative? ? ROOT.join(path) : path
  end

unless receipt_path.file?
  warn "FAIL: missing receipt #{receipt_path}"
  exit 1
end

receipt = JSON.parse(receipt_path.read(encoding: "UTF-8"))
errors = receipt_errors(receipt, live_id, live_version, live_commit)

if errors.empty?
  puts "PASS: receipt #{receipt_path.basename} matches #{live_id}"
else
  warn "FAIL: #{errors.length} receipt validation error(s)"
  errors.each { |error| warn "- #{error}" }
  exit 1
end
