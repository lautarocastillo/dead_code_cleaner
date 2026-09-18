require 'set'
require 'fileutils'

module DeadCodeCleaner
  # Detects JS functions/methods that have no detectable call anywhere else
  # in the app - other JS files, or ERB views (frameworks like Ralix expose
  # the current controller's methods as globals, called directly from
  # `onclick="..."` attributes in views).
  #
  # Detection is pattern-based (word/text search + brace counting), not a
  # real JS parser/AST - review the report before trusting it.
  class JsScanner
    Config = Struct.new(
      :root,                    # app root, used only to print relative paths in the report
      :js_dir,                  # where JS source lives
      :report_path,             # where to write the text report
      :usage_globs,             # glob(s) of source/template files to search for usage
      :excluded_path_fragments, # path fragments to exclude from definition/usage scanning
      :always_used_names,       # framework lifecycle method names never called by their literal name
      keyword_init: true
    )

    RESERVED_METHOD_NAMES = %w[if for while switch catch else do try function class].freeze

    # Parses a JS file for function declarations, `const`/`let` functions
    # (arrow or `function` expressions), and class method definitions. Class
    # methods are only recognized directly inside a `class ... { }` body -
    # tracked via a brace-context stack, same idea as the CSS ancestor-selector
    # stack - so an `if (...) {`/`for (...) {` inside a method isn't mistaken
    # for another method definition.
    module JsParser
      module_function

      def call(path)
        defs = []
        stack = []

        File.readlines(path, encoding: 'UTF-8').each_with_index do |raw_line, idx|
          line_no = idx + 1
          line = strip_comment(raw_line)
          stripped = line.strip
          next if stripped.empty?

          if (name = function_declaration_name(stripped)) || (name = const_function_name(stripped))
            defs << { name: name, file: path, line: line_no }
          elsif stack.last == :class && (name = method_definition_name(stripped))
            defs << { name: name, file: path, line: line_no }
          end

          push_brace_context(stack, stripped)
        end

        defs
      end

      def strip_comment(raw_line)
        raw_line.sub(%r{//.*}, '')
      end

      def function_declaration_name(stripped)
        m = stripped.match(/\A(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s*\*?\s*([A-Za-z_$][\w$]*)\s*\(/)
        m && m[1]
      end

      def const_function_name(stripped)
        m = stripped.match(/\A(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s+)?(?:function\b|.*=>)/)
        m && m[1]
      end

      def method_definition_name(stripped)
        m = stripped.match(/\A(?:static\s+)?(?:async\s+)?(?:get\s+|set\s+)?(?:\*\s*)?([A-Za-z_$][\w$]*)\s*\([^()]*\)\s*\{/)
        return nil unless m
        return nil if RESERVED_METHOD_NAMES.include?(m[1])

        m[1]
      end

      def push_brace_context(stack, stripped)
        return unless stripped.include?('{')

        if stripped.match?(/\A(?:export\s+)?(?:default\s+)?class\b/)
          stack.push(:class)
        else
          stack.push(:other)
        end

        stripped.count('}').times { stack.pop unless stack.empty? }
      end
    end

    def initialize(config)
      @config = config
      @defined = Hash.new { |h, k| h[k] = [] }
      @file_lines = {}
    end

    def run(delete:)
      js_files.each do |file|
        JsParser.call(file).each { |d| @defined[d[:name]] << { file: d[:file], line: d[:line] } }
      end

      token_counts = build_token_counts
      dynamic_fragments = collect_dynamic_fragments(corpus_files)

      unused = []
      needs_review = []
      always_used = []

      @defined.each do |name, occurrences|
        if config.always_used_names.include?(name)
          always_used << { name: name, occurrences: occurrences }
          next
        end

        total = token_counts[name] || 0
        extra = total - occurrences.size
        next if extra > 0 # found somewhere beyond its own definition(s)

        if dynamic_fragments[:prefixes].any? { |frag| name.start_with?(frag) } ||
           dynamic_fragments[:suffixes].any? { |frag| name.end_with?(frag) }
          needs_review << { name: name, occurrences: occurrences,
                             reason: 'matches a dynamically-built name fragment (template-literal interpolation) - verify manually' }
        else
          unused << { name: name, occurrences: occurrences }
        end
      end

      deleted, skipped = delete ? delete_unused!(unused) : [[], []]
      normalize_blank_lines!(js_files) if delete
      write_report(unused: unused, needs_review: needs_review, always_used: always_used,
                   deleted: deleted, skipped: skipped, deleted_mode: delete)
    end

    private

    attr_reader :config

    def js_files
      Dir.glob(File.join(config.js_dir, '**/*.js')).reject { |f| config.excluded_path_fragments.any? { |frag| f.include?(frag) } }.sort
    end

    def corpus_files
      files = config.usage_globs.flat_map { |glob| Dir.glob(glob) }
      files.reject { |f| config.excluded_path_fragments.any? { |frag| f.include?(frag) } }.uniq
    end

    def build_token_counts
      counts = Hash.new(0)
      corpus_files.each do |file|
        content = begin
          File.read(file, encoding: 'UTF-8')
        rescue StandardError
          next
        end
        content.scan(/[A-Za-z_$][\w$]*/) { |token| counts[token] += 1 }
      end
      counts
    end

    # Collects static text immediately touching template-literal interpolation
    # (`${...}`) so that names only ever built dynamically
    # (e.g. `this[`${tab}Controllers`]()`) aren't flagged as unused.
    def collect_dynamic_fragments(files)
      prefixes = Set.new
      suffixes = Set.new

      files.each do |file|
        content = begin
          File.read(file, encoding: 'UTF-8')
        rescue StandardError
          next
        end

        content.scan(/([A-Za-z0-9_$]{3,})\$\{[^{}]*\}/) { |(frag)| prefixes << frag }
        content.scan(/\$\{[^{}]*\}([A-Za-z0-9_$]{3,})/) { |(frag)| suffixes << frag }
      end

      { prefixes: prefixes, suffixes: suffixes }
    end

    def delete_unused!(unused)
      deletions_by_file = Hash.new { |h, k| h[k] = [] }
      deleted = []
      skipped = []

      unused.each do |entry|
        entry[:occurrences].each do |occ|
          lines = (@file_lines[occ[:file]] ||= File.readlines(occ[:file], encoding: 'UTF-8'))
          def_idx = occ[:line] - 1
          end_idx = definition_end_index(lines, def_idx)

          if safe_to_delete?(lines, def_idx, end_idx)
            deletions_by_file[occ[:file]] << { name: entry[:name], range: def_idx..end_idx }
          else
            skipped << { name: entry[:name], file: occ[:file], line: occ[:line] }
          end
        end
      end

      deletions_by_file.each do |file, occs|
        lines = @file_lines[file]

        merge_ranges(occs).each do |merged|
          lines.slice!(merged[:range])
          deleted << { name: merged[:names].join(', '), file: file, line: merged[:range].begin + 1 }
        end

        collapse_consecutive_blank_lines!(lines)
        File.write(file, lines.join)
      end

      [deleted, skipped]
    end

    # Squashes any run of 2+ consecutive blank lines down to 1, wherever it occurs.
    def collapse_consecutive_blank_lines!(lines)
      i = 1
      while i < lines.size
        if lines[i].strip.empty? && lines[i - 1].strip.empty?
          lines.slice!(i)
        else
          i += 1
        end
      end
    end

    # Runs across every JS file (not just ones with a deletion this run),
    # since double blank lines can pre-exist independently of this scanner.
    def normalize_blank_lines!(files)
      files.each do |file|
        lines = File.readlines(file, encoding: 'UTF-8')
        original_size = lines.size
        collapse_consecutive_blank_lines!(lines)
        File.write(file, lines.join) if lines.size != original_size
      end
    end

    # Only trusts a boundary when the definition closes with a bare `}` (optionally
    # `};`/`})`) - a single-line arrow/expression definition is always safe.
    def safe_to_delete?(lines, def_idx, end_idx)
      return true if end_idx == def_idx

      lines[end_idx].strip.match?(/\A\}[;,)]?\z/)
    end

    def definition_end_index(lines, def_idx)
      def_line = lines[def_idx]
      depth = def_line.count('{') - def_line.count('}')
      return def_idx if depth <= 0

      idx = def_idx + 1
      while idx < lines.size
        depth += lines[idx].count('{') - lines[idx].count('}')
        return idx if depth <= 0

        idx += 1
      end
      lines.size - 1
    end

    # Merges overlapping/nested ranges (sorted so we can slice safely in one pass).
    def merge_ranges(raw_ranges)
      sorted = raw_ranges.sort_by { |r| [r[:range].begin, -r[:range].end] }
      merged = []

      sorted.each do |r|
        last = merged.last
        if last && r[:range].begin <= last[:range].end
          last[:range] = last[:range].begin..[last[:range].end, r[:range].end].max
          last[:names] << r[:name]
        else
          merged << { range: r[:range], names: [r[:name]] }
        end
      end

      merged.sort_by { |m| -m[:range].begin }
    end

    def write_report(unused:, needs_review:, always_used:, deleted:, skipped:, deleted_mode:)
      lines = []
      lines << "# Unused JS function report (#{Time.now})"
      lines << ''
      lines << "Mode: #{deleted_mode ? 'DELETE (high-confidence unused functions removed)' : 'DRY RUN (no files modified)'}"
      lines << ''

      if deleted_mode
        lines << "== Deleted functions (#{deleted.size}) =="
        deleted.each { |d| lines << "  #{d[:name]}  #{relative(d[:file])}:#{d[:line]}" }
        lines << ''
        lines << "== Skipped, could not safely determine boundaries (#{skipped.size}) =="
        skipped.each { |s| lines << "  #{s[:name]}  #{relative(s[:file])}:#{s[:line]}" }
        lines << ''
      end

      remaining_unused = deleted_mode ? [] : unused
      lines << "== Unused, high confidence (#{remaining_unused.size}) =="
      remaining_unused.each do |u|
        locations = u[:occurrences].map { |o| "#{relative(o[:file])}:#{o[:line]}" }.join(', ')
        lines << "  #{u[:name]}  (#{locations})"
      end
      lines << ''

      lines << "== Needs manual review (#{needs_review.size}) =="
      needs_review.each do |nr|
        locations = nr[:occurrences].map { |o| "#{relative(o[:file])}:#{o[:line]}" }.join(', ')
        lines << "  #{nr[:name]}  (#{locations}) - #{nr[:reason]}"
      end
      lines << ''

      lines << "== Framework lifecycle names, excluded from checks (#{always_used.size}) =="
      always_used.each do |au|
        locations = au[:occurrences].map { |o| "#{relative(o[:file])}:#{o[:line]}" }.join(', ')
        lines << "  #{au[:name]}  (#{locations})"
      end

      report = lines.join("\n")
      FileUtils.mkdir_p(File.dirname(config.report_path))
      File.write(config.report_path, report)
      puts report
      puts "\nFull report written to #{relative(config.report_path)}"
    end

    def relative(path)
      path.sub("#{config.root}/", '')
    end
  end
end
