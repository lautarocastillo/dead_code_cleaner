require 'set'
require 'fileutils'

module DeadCodeCleaner
  # Detects Ruby methods (`def` or literal `define_method`) defined in a
  # given directory that have no detectable call anywhere else in the app
  # (views, other classes, jobs, specs...).
  #
  # This single engine replaces what used to be five near-identical scanners
  # (controllers/helpers/models/searchers/services) - it works on any
  # `app/**/*.rb` directory, so one `Config` covers all of them. See
  # lib/tasks/dead_code_cleaner.rake for how it's wired up as rake tasks.
  #
  # Detection is pattern-based (word/text search), not a real Ruby parser, so:
  #   - a method is only counted as "used" if its name appears as a plain
  #     identifier somewhere else (covers `foo`, `foo(...)`, `:foo`, `foo?`,
  #     `foo!`, `send(:foo)`, `before_action :foo`, a route line, etc.)
  #   - setter methods (`def foo=`) are always sent to manual review, since
  #     `object.foo = value` call sites can't be told apart from a plain
  #     local variable assignment by a text scan
  #   - methods only ever invoked dynamically (name built via string
  #     interpolation, e.g. `send("#{prefix}_path")`) are detected via
  #     dynamic-fragment matching and sent to manual review instead of "unused"
  #   - `define_method` calls whose name isn't a literal symbol/string can't
  #     be resolved to a method name at all; they're listed separately under
  #     "dynamically defined" and are never candidates for deletion
  # Because Ruby method boundaries (multi-line blocks, endless `def foo =
  # expr`, one-line `if ... end`, heredocs, etc.) are much harder to find
  # reliably than CSS's `{ }` braces, deletion is conservative: it defaults
  # to OFF, and any method whose boundaries can't be confidently determined
  # is skipped and reported instead of deleted.
  class RubyMethodScanner
    BLOCK_KEYWORDS = %w[def if unless case begin while until class module for].freeze

    Config = Struct.new(
      :root,                    # app root, used only to print relative paths in the report
      :dir,                     # directory to scan for `.rb` definitions, e.g. "app/models"
      :label,                   # short label used in the report title/filename, e.g. "model"
      :report_path,             # where to write the text report
      :usage_globs,             # glob(s) of files to search for usages
      :excluded_path_fragments, # path fragments to exclude from usage scanning (build output, vendor)
      :always_used_names,       # method names invoked reflectively/by the framework - never flagged
      keyword_init: true
    )

    def initialize(config)
      @config = config
      @defined = Hash.new { |h, k| h[k] = [] }
      @dynamic_defs = []
      @file_lines = {}
    end

    def run(delete:)
      target_files.each do |file|
        result = parse_file(file)
        result[:defs].each { |d| @defined[d[:name]] << { file: d[:file], line: d[:line] } }
        @dynamic_defs.concat(result[:dynamic_defs])
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

        if name.end_with?('=')
          needs_review << { name: name, occurrences: occurrences,
                             reason: 'setter method - assignment-style calls (`obj.foo = x`) cannot be reliably detected by a text scan; verify manually' }
          next
        end

        total = token_counts[name] || 0
        extra = total - occurrences.size
        next if extra > 0 # found somewhere beyond its own definition(s)

        if dynamic_fragments[:prefixes].any? { |frag| name.start_with?(frag) } ||
           dynamic_fragments[:suffixes].any? { |frag| name.end_with?(frag) }
          needs_review << { name: name, occurrences: occurrences,
                             reason: 'matches a dynamically-built method-name fragment (string interpolation) - verify manually' }
        else
          unused << { name: name, occurrences: occurrences }
        end
      end

      deleted, skipped = delete ? delete_unused!(unused) : [[], []]
      normalize_blank_lines!(target_files) if delete
      write_report(unused: unused, needs_review: needs_review, dynamic_defs: @dynamic_defs,
                   always_used: always_used, deleted: deleted, skipped: skipped, deleted_mode: delete)
    end

    private

    attr_reader :config

    def target_files
      Dir.glob(File.join(config.dir, '**/*.rb')).sort
    end

    def corpus_files
      files = config.usage_globs.flat_map { |glob| Dir.glob(glob) }
      files.reject { |f| config.excluded_path_fragments.any? { |frag| f.include?(frag) } }.uniq
    end

    def parse_file(path)
      defs = []
      dynamic_defs = []

      File.readlines(path, encoding: 'UTF-8').each_with_index do |raw_line, idx|
        line_no = idx + 1
        stripped = raw_line.sub(/#.*/, '').strip
        next if stripped.empty?

        if (m = stripped.match(/\A(?:private\s+|protected\s+|public\s+)?def\s+(?:self\.)?([A-Za-z_]\w*[?!]?=?)/))
          defs << { name: m[1], file: path, line: line_no }
        elsif stripped.include?('define_method')
          name = literal_define_method_name(stripped)
          if name
            defs << { name: name, file: path, line: line_no }
          else
            dynamic_defs << { file: path, line: line_no, snippet: stripped }
          end
        end
      end

      { defs: defs, dynamic_defs: dynamic_defs }
    end

    def literal_define_method_name(stripped)
      return nil if stripped.include?('#{')

      if (m = stripped.match(/define_method\s*\(?\s*:"?'?([A-Za-z_]\w*[?!]?=?)"?'?/))
        return m[1]
      end

      m = stripped.match(/define_method\s*\(?\s*["']([A-Za-z_]\w*[?!]?=?)["']/)
      m && m[1]
    end

    # Collects static text immediately touching string interpolation
    # (Ruby "#{...}") so that method names only ever spelled out dynamically
    # (e.g. `send("#{prefix}_path")`) aren't flagged as unused.
    def collect_dynamic_fragments(files)
      prefixes = Set.new
      suffixes = Set.new

      files.each do |file|
        content = begin
          File.read(file, encoding: 'UTF-8')
        rescue StandardError
          next
        end

        content.scan(/([A-Za-z0-9_]{3,})#\{[^{}]*\}/) { |(frag)| prefixes << frag }
        content.scan(/#\{[^{}]*\}([A-Za-z0-9_]{3,})/) { |(frag)| suffixes << frag }
      end

      { prefixes: prefixes, suffixes: suffixes }
    end

    def build_token_counts
      counts = Hash.new(0)
      corpus_files.each do |file|
        content = begin
          File.read(file, encoding: 'UTF-8')
        rescue StandardError
          next
        end
        # Identifier plus an optional trailing `?`/`!` so `valid?`/`save!` match as one token.
        content.scan(/[A-Za-z_]\w*[?!]?/) { |token| counts[token] += 1 }
      end
      counts
    end

    def delete_unused!(unused)
      deletions_by_file = Hash.new { |h, k| h[k] = [] }
      deleted = []
      skipped = []

      unused.each do |entry|
        entry[:occurrences].each do |occ|
          lines = (@file_lines[occ[:file]] ||= File.readlines(occ[:file], encoding: 'UTF-8'))
          def_idx = occ[:line] - 1
          end_idx = method_end_index(lines, def_idx)

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

    # Runs across every target file (not just ones with a deletion this run),
    # since double blank lines can pre-exist independently of this scanner.
    def normalize_blank_lines!(files)
      files.each do |file|
        lines = File.readlines(file, encoding: 'UTF-8')
        original_size = lines.size
        collapse_consecutive_blank_lines!(lines)
        File.write(file, lines.join) if lines.size != original_size
      end
    end

    # Refuses to delete unless the detected end is unambiguous: a bare `end`
    # line, indented the same as its `def` (or the whole method is a one-line
    # endless `def foo = expr`). Anything less certain is left for review.
    def safe_to_delete?(lines, def_idx, end_idx)
      return true if end_idx == def_idx

      end_line = lines[end_idx]
      return false unless end_line.strip == 'end'

      lines[def_idx][/\A */].size == end_line[/\A */].size
    end

    def method_end_index(lines, def_idx)
      def_stripped = lines[def_idx].sub(/#.*/, '').strip
      return def_idx if endless_def?(def_stripped)

      depth = 1
      idx = def_idx + 1
      while idx < lines.size
        stripped = lines[idx].sub(/#.*/, '').strip
        depth += 1 if opens_block?(stripped)
        depth -= 1 if stripped == 'end'
        return idx if depth <= 0

        idx += 1
      end
      lines.size - 1
    end

    # `def foo = expr` / `def foo(x) = expr` (Ruby 3+) has no matching `end`.
    # A trailing `=` right after the method name (`def foo=`) is a setter, not this.
    def endless_def?(stripped)
      m = stripped.match(/\A(?:private\s+|protected\s+|public\s+)?def\s+(?:self\.)?[A-Za-z_]\w*([?!]|=)?\s*(\([^)]*\))?\s*=\s*\S/)
      return false unless m

      m[1] != '='
    end

    def opens_block?(stripped)
      return false if stripped.empty?
      return true if stripped.match?(/(^|[\s.])do(\s*\|[^|]*\|)?\z/)

      BLOCK_KEYWORDS.include?(stripped[/\A\S+/])
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

    def write_report(unused:, needs_review:, dynamic_defs:, always_used:, deleted:, skipped:, deleted_mode:)
      lines = []
      lines << "# Unused #{config.label} method report (#{Time.now})"
      lines << ''
      lines << "Mode: #{deleted_mode ? 'DELETE (high-confidence unused methods removed)' : 'DRY RUN (no files modified)'}"
      lines << ''

      if deleted_mode
        lines << "== Deleted methods (#{deleted.size}) =="
        deleted.each { |d| lines << "  #{d[:name]}  #{relative(d[:file])}:#{d[:line]}" }
        lines << ''
        lines << "== Skipped, could not safely determine method boundaries (#{skipped.size}) =="
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

      lines << "== Dynamically defined, name not statically known (#{dynamic_defs.size}) =="
      dynamic_defs.each { |d| lines << "  #{relative(d[:file])}:#{d[:line]}  #{d[:snippet]}" }
      lines << ''

      lines << "== Framework-invoked names, excluded from checks (#{always_used.size}) =="
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
