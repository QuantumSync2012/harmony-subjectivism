# frozen_string_literal: true

require "digest"
require_relative "hs_release"

# manifest/receiptのprovenanceをlive実値と照合する(CF NO-GO P1-4対応)。
# keyの存在ではなく値をHEAD・registry・generator実hashへ束縛する。
module HsProvenance
  module_function

  # liveを注入可能にしてselftestで負例を検証する
  def live_state
    {
      "source_commit" => HsRelease.source_commit,
      "release_id" => HsRelease.release_id,
      "pack_version" => HsRelease.pack_version,
      "registry_sha256" => HsRelease.registry_sha256,
      "generator_sha256" => Digest::SHA256.file(HsRelease::ROOT.join("scripts/build_rag_core.rb")).hexdigest
    }
  end

  def manifest_errors(manifest, live = live_state)
    errors = []
    errors << "manifest schema_version must be 1" unless manifest["schema_version"] == 1
    errors << "manifest source_commit #{manifest['source_commit'].to_s[0, 12]} != HEAD #{live['source_commit'][0, 12]}" unless manifest["source_commit"] == live["source_commit"]
    errors << "manifest release_id #{manifest['release_id']} != #{live['release_id']}" unless manifest["release_id"] == live["release_id"]
    errors << "manifest pack_version #{manifest['pack_version']} != registry #{live['pack_version']}" unless manifest["pack_version"] == live["pack_version"]
    errors << "manifest registry_sha256 does not match live registry" unless manifest["registry_sha256"] == live["registry_sha256"]
    errors << "manifest generator_sha256 does not match live generator" unless manifest["generator_sha256"] == live["generator_sha256"]
    errors << "manifest generator_path must be scripts/build_rag_core.rb" unless manifest["generator_path"] == "scripts/build_rag_core.rb"
    # release受入条件: source cleanで作られたartifactのみ(P1-3/P1-4)
    errors << "manifest source_dirty must be false" unless manifest["source_dirty"] == false
    errors
  end
end
