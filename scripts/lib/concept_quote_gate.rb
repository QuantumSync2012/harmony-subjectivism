# frozen_string_literal: true

require "pathname"
require "yaml"

module ConceptQuoteGate
  ROOT = Pathname.new(__dir__).join("../..").expand_path
  REGISTRY = YAML.load_file(ROOT.join("research/hs-id-registry.yaml"))
  ENTRIES = REGISTRY.fetch("entries").each_with_object({}) { |entry, memo| memo[entry.fetch("id")] = entry }

  # Pages without an entity_ref still quote canon at the top of the page. Each
  # quote is tied to one exact source heading so an identical sentence
  # elsewhere in canon cannot accidentally validate it.
  MANUAL_QUOTE_SPECS = {
    "wiki/concepts/aruji.md" => [
      { source: "canon/glossary.md", heading: "#### 主（あるじ）【定義】", source_prefix: "**定義**:" }
    ],
    "wiki/concepts/ba.md" => [
      { source: "canon/glossary.md", heading: "#### 場（ば）【定義】", source_prefix: "**定義**:" }
    ],
    "wiki/concepts/busshitsu.md" => [
      { source: "canon/glossary.md", heading: "#### 物質（ぶっしつ）【定義】", source_prefix: "**定義**:" }
    ],
    "wiki/concepts/chowa.md" => [
      { source: "canon/glossary.md", heading: "#### 調和（ちょうわ）——生成する調和【定義】", source_prefix: "**定義**:" }
    ],
    "wiki/concepts/gyo.md" => [
      {
        source: "canon/principles.md",
        heading: "### 第二原理 観（Kan）【定義】",
        excerpt: "観は**受・想・行・識**の四位相を持つ——受（受けとる）・想（かたちを結ぶ）・行（形成へ向かう）・識（識る）。"
      },
      { source: "canon/glossary.md", heading: "#### 行の変換（こうのへんかん）【定義】", source_prefix: "**定義**:" }
    ],
    "wiki/concepts/ittaikan.md" => [
      { source: "canon/glossary.md", heading: "#### 一体感（いったいかん）【定義】", source_prefix: "**定義**:" }
    ],
    "wiki/concepts/ji-series.md" => [
      { source: "canon/glossary.md", heading: "#### 自（じ）【定義】", source_prefix: "**定義**:", display_prefix: "**自**:" },
      { source: "canon/glossary.md", heading: "#### 己（こ）【定義】", source_prefix: "**定義**:", display_prefix: "**己**:" },
      { source: "canon/glossary.md", heading: "#### 自己（じこ）【定義】", source_prefix: "**定義**:", display_prefix: "**自己**:" },
      { source: "canon/glossary.md", heading: "#### 自分（じぶん）【定義】", source_prefix: "**定義**:", display_prefix: "**自分**:" },
      { source: "canon/glossary.md", heading: "#### 我（が）【定義】", source_prefix: "**定義**:", display_prefix: "**我**:" }
    ],
    "wiki/concepts/jikan.md" => [
      { source: "canon/glossary.md", heading: "#### 時間の二層【定義】", source_prefix: "**定義**:" }
    ],
    "wiki/concepts/ju.md" => [
      {
        source: "canon/principles.md",
        heading: "### 第二原理 観（Kan）【定義】",
        excerpt: "観は**受・想・行・識**の四位相を持つ——受（受けとる）・想（かたちを結ぶ）・行（形成へ向かう）・識（識る）。"
      },
      { source: "canon/glossary.md", heading: "#### 受の能動性【定義】", source_prefix: "**定義**:" }
    ],
    "wiki/concepts/kakurikai.md" => [
      { source: "canon/glossary.md", heading: "#### 玄り界（かくりかい）【定義】", source_prefix: "**定義**:" }
    ],
    "wiki/concepts/kansha.md" => [
      { source: "canon/glossary.md", heading: "#### 感謝（かんしゃ）【定義】", source_prefix: "**定義**:" }
    ],
    "wiki/concepts/katachi.md" => [
      {
        source: "canon/principles.md",
        heading: "### 第十一原理 型と形【定義】",
        excerpt: "型とは、物を縛る則である。形とは、その型に依って現れている物が持つ、現れの姿である（筆者定式「型は物を縛る法則で、それに依って現れている物が形を持つ」による）。型は則の側の語、形は現れの側の語である。"
      }
    ],
    "wiki/concepts/kate.md" => [
      { source: "canon/glossary.md", heading: "#### 糧（かて）【定義】", source_prefix: "**定義**:" }
    ],
    "wiki/concepts/kyokan.md" => [
      { source: "canon/glossary.md", heading: "#### 共感（きょうかん）【定義】", source_prefix: "**定義**:" }
    ],
    "wiki/concepts/moji.md" => [
      {
        source: "canon/principles.md",
        heading: "### 定理九（文字による時越えの形成）【定理】",
        excerpt: "文字は、観の行が物に変わったもの——時に耐える媒介である。"
      },
      {
        source: "canon/principles.md",
        heading: "### 定理九（文字による時越えの形成）【定理】",
        excerpt: "文字は、情を帯びた観の行が物として形を取ったものである。それが他鼎へ届くと、受け手に客鼎観と新たな情が成立する。"
      }
    ],
    "wiki/concepts/ritsu.md" => [
      { source: "canon/glossary.md", heading: "#### 律する（りっする）【定義】", source_prefix: "**定義**:" }
    ],
    "wiki/concepts/shiki.md" => [
      {
        source: "canon/principles.md",
        heading: "### 第二原理 観（Kan）【定義】",
        excerpt: "観は**受・想・行・識**の四位相を持つ——受（受けとる）・想（かたちを結ぶ）・行（形成へ向かう）・識（識る）。"
      }
    ],
    "wiki/concepts/shin.md" => [
      { source: "canon/glossary.md", heading: "#### 信じる（しんじる）【定義】", source_prefix: "**定義**:" }
    ],
    "wiki/concepts/so.md" => [
      {
        source: "canon/principles.md",
        heading: "### 第二原理 観（Kan）【定義】",
        excerpt: "観は**受・想・行・識**の四位相を持つ——受（受けとる）・想（かたちを結ぶ）・行（形成へ向かう）・識（識る）。"
      }
    ],
    "wiki/concepts/sokutei.md" => [
      {
        source: "canon/glossary.md",
        heading: "#### 測定（そくてい）【定義】",
        excerpt: "**定義**: 量子力学等の文脈で用いる語。"
      }
    ],
    "wiki/concepts/sonzai.md" => [
      { source: "canon/glossary.md", heading: "#### 存在（そんざい）【定義】", excerpt: "**定義**: 在ること。" }
    ],
    "wiki/concepts/tai.md" => [
      { source: "canon/glossary.md", heading: "#### 體（たい／表示・検索alias: 体）【定義】", source_prefix: "**定義**:" }
    ],
    "wiki/concepts/tamashii.md" => [
      {
        source: "canon/glossary.md",
        heading: "#### 魂と呼ばれてきたもの【解釈】",
        source_prefix: "**位置づけ**:",
        remove: "（→三、不採用・廃語台帳）"
      }
    ],
    "wiki/concepts/teigo.md" => [
      { source: "canon/glossary.md", heading: "#### 鼎合（ていごう）【系】（2026-08-14 筆者による最終宣言）", source_prefix: "**定義**:" }
    ],
    "wiki/concepts/teiritsu.md" => [
      { source: "canon/glossary.md", heading: "#### 鼎立（ていりつ）【定義】", source_prefix: "**定義**:" }
    ],
    "wiki/concepts/tomoshibi.md" => [
      { source: "canon/glossary.md", heading: "#### 灯（ともしび）【定義】", source_prefix: "**定義**:", display_prefix: "**灯の定義**:" },
      { source: "canon/glossary.md", heading: "#### 光（ひかり）【定義】", source_prefix: "**定義**:", display_prefix: "**光の定義**:" },
      { source: "canon/glossary.md", heading: "#### 伝灯（でんとう）【定義】", source_prefix: "**定義**:", display_prefix: "**伝灯の定義**:" }
    ],
    "wiki/concepts/utsushikai.md" => [
      { source: "canon/glossary.md", heading: "#### 現し界（うつしかい）【定義】", source_prefix: "**定義**:" }
    ],
    "wiki/concepts/zen.md" => [
      { source: "canon/glossary.md", heading: "#### 然（ぜん）【定義】", source_prefix: "**定義**:" }
    ]
  }.freeze

  NON_DEFINITION_PAGES = ["wiki/concepts/index.md"].freeze

  module_function

  def source_section(relative, heading)
    lines = ROOT.join(relative).read(encoding: "UTF-8").lines
    start = lines.index { |line| line.chomp == heading }
    raise "#{relative}: source heading not found: #{heading}" unless start

    level = heading[/\A#+/].length
    finish = ((start + 1)...lines.length).find do |index|
      match = lines[index].match(/\A(#+)\s/)
      match && match[1].length <= level
    end || lines.length
    lines[(start + 1)...finish].join
  end

  def expected_manual_quote(spec)
    section = source_section(spec.fetch(:source), spec.fetch(:heading))
    canonical = if spec[:source_prefix]
                  section.each_line.map(&:strip).find { |line| line.start_with?(spec.fetch(:source_prefix)) }
                else
                  spec.fetch(:excerpt) if section.include?(spec.fetch(:excerpt))
                end
    raise "#{spec.fetch(:source)}: canonical excerpt missing under #{spec.fetch(:heading)}" unless canonical

    canonical = canonical.sub(spec.fetch(:source_prefix), spec.fetch(:display_prefix)) if spec[:display_prefix]
    canonical = canonical.sub(spec.fetch(:remove), "") if spec[:remove]
    "> #{canonical}"
  end

  def displayed_quotes(text)
    before_first_section = text.split(/^##\s/, 2).first
    before_first_section.each_line.map(&:strip).select { |line| line.start_with?("> ") }
  end

  def definition_line(entry)
    relative, anchor = entry.fetch("path").split("#", 2)
    source = ROOT.join(relative).read(encoding: "UTF-8")
    anchor_line = %(<a id="#{anchor}"></a>)
    offset = source.index(anchor_line)
    raise "#{entry.fetch('id')}: source anchor not found" unless offset

    tail = source[(offset + anchor_line.length)..]
    line = tail.each_line.map(&:strip).find { |candidate| candidate.start_with?("**定義**:") }
    raise "#{entry.fetch('id')}: canonical definition line not found" unless line

    [relative, line]
  end

  def run(write: false, quiet: false)
    errors = []
    generated_checked = 0
    mapped_checked = 0
    generated_pages = {}

    Dir.glob(ROOT.join("wiki/concepts/*.md")).sort.each do |filename|
      relative_path = Pathname.new(filename).relative_path_from(ROOT).to_s
      text = File.read(filename, encoding: "UTF-8")

      if text.start_with?("---\n")
        frontmatter = text.split("---\n", 3)[1]
        entity_ref = frontmatter[/^entity_ref:\s*(HS-C-\d{4})\s*$/, 1]
        if entity_ref
          entry = ENTRIES[entity_ref]
          unless entry
            errors << "#{relative_path}: unknown entity_ref #{entity_ref}"
            next
          end
          if generated_pages.key?(entity_ref)
            errors << "#{relative_path}: duplicate generated page for #{entity_ref} (also #{generated_pages[entity_ref]})"
            next
          end
          generated_pages[entity_ref] = relative_path

          begin_marker = "<!-- HS-DEF-QUOTE:BEGIN id=#{entity_ref}"
          block_pattern = /<!-- HS-DEF-QUOTE:BEGIN id=#{Regexp.escape(entity_ref)}[^\n]* -->\n.*?\n<!-- HS-DEF-QUOTE:END -->/m
          unless text.include?(begin_marker) && text.match?(block_pattern)
            errors << "#{relative_path}: generated definition quote block missing"
            next
          end

          begin
            relative, line = definition_line(entry)
            revision = entry.fetch("active_revision")
            expected = [
              "<!-- HS-DEF-QUOTE:BEGIN id=#{entity_ref} revision=#{revision} source=#{relative} -->",
              "> #{line}",
              "<!-- HS-DEF-QUOTE:END -->"
            ].join("\n")

            if text.match(block_pattern)[0] != expected
              if write
                File.write(filename, text.sub(block_pattern, expected), encoding: "UTF-8")
              else
                errors << "#{relative_path}: generated definition quote drift"
              end
            end
            generated_checked += 1
          rescue KeyError, RuntimeError => e
            errors << "#{relative_path}: #{e.message}"
          end
          next
        end
      end

      if (specs = MANUAL_QUOTE_SPECS[relative_path])
        begin
          expected_quotes = specs.map { |spec| expected_manual_quote(spec) }
          actual_quotes = displayed_quotes(text)
          if actual_quotes != expected_quotes
            errors << "#{relative_path}: mapped canonical quote drift (expected #{expected_quotes.length}, found #{actual_quotes.length})"
          end
          if text.include?("HS-DEF-QUOTE:BEGIN")
            errors << "#{relative_path}: generated quote marker is reserved for registry-managed pages"
          end
          mapped_checked += 1
        rescue KeyError, RuntimeError => e
          errors << "#{relative_path}: #{e.message}"
        end
      elsif NON_DEFINITION_PAGES.include?(relative_path)
        unless displayed_quotes(text).empty?
          errors << "#{relative_path}: navigation page must not display a canonical blockquote"
        end
      else
        errors << "#{relative_path}: concept page has no canonical quote mapping"
      end
    end

    active_ids = ENTRIES.values.select { |entry| entry["status"] == "active" }.map { |entry| entry.fetch("id") }.sort
    missing_generated = active_ids - generated_pages.keys.sort
    extra_generated = generated_pages.keys.sort - active_ids
    errors << "active registry concepts missing generated pages: #{missing_generated.join(', ')}" unless missing_generated.empty?
    errors << "non-active concepts have generated pages: #{extra_generated.join(', ')}" unless extra_generated.empty?

    known_pages = generated_pages.values + MANUAL_QUOTE_SPECS.keys + NON_DEFINITION_PAGES
    actual_pages = Dir.glob(ROOT.join("wiki/concepts/*.md")).map do |filename|
      Pathname.new(filename).relative_path_from(ROOT).to_s
    end
    unclassified = actual_pages - known_pages
    errors << "unclassified concept pages: #{unclassified.sort.join(', ')}" unless unclassified.empty?

    if errors.empty?
      action = write ? "synchronized and verified" : "verified"
      unless quiet
        puts "PASS: #{action} #{generated_checked} generated and #{mapped_checked} canon-mapped definition page(s); #{NON_DEFINITION_PAGES.length} navigation page(s) classified"
      end
      return 0
    end

    unless quiet
      warn "FAIL: #{errors.length} definition quote error(s)"
      errors.each { |error| warn "- #{error}" }
    end
    1
  end
end
