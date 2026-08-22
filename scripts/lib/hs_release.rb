# frozen_string_literal: true

require "digest"
require "pathname"

# release単位の版・出自の唯一の導出点。
# 版のmachine-readable正本は research/hs-id-registry.yaml の registry_version であり、
# 各scriptはここを経由して読む(手書き定数の版drift再発防止・統合修正仕様v1 §6)。
module HsRelease
  ROOT = Pathname.new(File.expand_path("../..", __dir__))
  REGISTRY_PATH = ROOT.join("research/hs-id-registry.yaml")

  module_function

  def registry_version
    text = REGISTRY_PATH.read(encoding: "UTF-8")
    match = text.match(/^registry_version:\s*(\S+)\s*$/)
    raise "registry_version not found in #{REGISTRY_PATH}" unless match

    match[1]
  end

  def pack_version
    registry_version
  end

  def source_commit
    commit = git("rev-parse", "HEAD")
    raise "cannot resolve git HEAD" if commit.empty?

    commit
  end

  def release_id
    "hs-v#{registry_version}+#{source_commit[0, 7]}"
  end

  # HEADで追跡されているfileの集合(相対path)。untracked sourceのfail-closed判定に使う(CF NO-GO P1-3)
  def tracked_files
    git("ls-files").split("\n").to_a
  end

  # 指定path群に限定したworking treeの汚れ(未追跡を含む)。空配列なら全体のtracked変更のみを見る。
  # 注: git()は全体をstripするため先頭行のstatus列幅が揺れる。固定offsetでなくstatus token除去でparseする
  def dirty_paths(paths = [])
    if paths.empty?
      git("status", "--porcelain", "--untracked-files=no")
    else
      git("status", "--porcelain", "--", *paths)
    end.split("\n").map { |line| line.strip.sub(/\A\S{1,2}\s+/, "") }.reject(&:empty?)
  end

  def registry_sha256
    Digest::SHA256.file(REGISTRY_PATH).hexdigest
  end

  def git(*args)
    IO.popen(["git", "-C", ROOT.to_s, *args], err: File::NULL, &:read).to_s.strip
  end
end
