require 'set'
require 'json'
require 'fileutils'

module DeadCodeCleaner
  # Detects CSS classes defined under a stylesheets directory that have no
  # detectable usage elsewhere in the app (views, helpers, JS, other
  # stylesheets). See lib/tasks/dead_code_cleaner.rake for how it's wired up.
  #
  # Detection is pattern-based, not a real CSS/JS parser, and naming
  # conventions differ across repos - run with delete: false first and
  # spot-check a sample of "unused" results by hand.
  class CssScanner
    Config = Struct.new(
      :root,                       # app root, used to resolve package.json/node_modules and relative report paths
      :stylesheets_dir,             # where CSS/SCSS lives
      :report_path,                 # where to write the text report
      :usage_globs,                 # glob(s) of template/source files to search for class usage
      :excluded_path_fragments,     # path fragments to exclude from usage scanning (build output)
      :vendor_override_filenames,   # filenames that only style vendor-injected markup - never flagged
      keyword_init: true
    )

    # Sass %placeholders are intentionally ignored: they never reach the DOM
    # as classes, so "unused class" scanning doesn't apply to them.
    module ScssParser
      module_function

      def call(path)
        classes = []
        brace_stack = []
        in_block_comment = false

        File.readlines(path, encoding: 'UTF-8').each_with_index do |raw_line, idx|
          line_no = idx + 1
          line = raw_line.dup

          if in_block_comment
            close_idx = line.index('*/')
            if close_idx
              line = line[(close_idx + 2)..] || ''
              in_block_comment = false
            else
              next
            end
          end

          loop do
            open_idx = line.index('/*')
            break unless open_idx

            close_idx = line.index('*/', open_idx)
            if close_idx
              line = line[0...open_idx] + line[(close_idx + 2)..]
            else
              line = line[0...open_idx]
              in_block_comment = true
              break
            end
          end
          line = line.sub(%r{//.*}, '')
          next if line.strip.empty?

          has_open = line.include?('{')
          selector_part = has_open ? line.split('{', 2).first.strip : nil
          resolved_ancestor = nil

          if has_open
            is_at_rule = selector_part.nil? || selector_part.empty? || selector_part.start_with?('@')
            current_ancestor = brace_stack.reverse.find { |ancestor| ancestor }

            unless is_at_rule
              pieces = selector_part.split(',')
              pieces.each do |raw_piece|
                piece = raw_piece.strip
                next if piece.empty?

                piece.scan(/\.([A-Za-z][A-Za-z0-9_-]*)/).each do |(name)|
                  exclusive = pieces.size == 1 && piece == ".#{name}"
                  classes << { name: name, file: path, line: line_no, exclusive: exclusive }
                  resolved_ancestor ||= name
                end

                next unless current_ancestor

                modifier_match = piece.match(/\A&(--|__)([A-Za-z0-9_-]+)/)
                next unless modifier_match

                combined = "#{current_ancestor}#{modifier_match[1]}#{modifier_match[2]}"
                classes << { name: combined, file: path, line: line_no, exclusive: false }
                resolved_ancestor ||= combined
              end
            end

            brace_stack.push(resolved_ancestor)
          end

          line.count('}').times { brace_stack.pop unless brace_stack.empty? }
        end

        classes
      end
    end

    def initialize(config)
      @config = config
      @defined = Hash.new { |h, k| h[k] = [] }
    end

    def run(delete:)
      scss_files.each do |file|
        ScssParser.call(file).each do |c|
          @defined[c[:name]] << { file: c[:file], line: c[:line], exclusive: c[:exclusive] }
        end
      end

      token_counts = build_token_counts
      vendor_token_counts = build_vendor_token_counts
      dynamic_fragments = collect_dynamic_fragments(ruby_and_js_files)

      unused = []
      needs_review = []
      excluded_vendor = []

      @defined.each do |name, occurrences|
        if occurrences.any? { |o| vendor_override_file?(o[:file]) }
          excluded_vendor << { name: name, occurrences: occurrences }
          next
        end

        total = token_counts[name] || 0
        extra = total - occurrences.size
        next if extra > 0 # found somewhere beyond its own definition(s)

        if (vendor_token_counts[name] || 0).positive?
          excluded_vendor << { name: name, occurrences: occurrences }
        elsif dynamic_fragments[:prefixes].any? { |frag| name.start_with?(frag) } ||
              dynamic_fragments[:suffixes].any? { |frag| name.end_with?(frag) }
          needs_review << { name: name, occurrences: occurrences, reason: 'matches a dynamically-built class-name fragment (string interpolation)' }
        elsif occurrences.all? { |o| o[:exclusive] }
          unused << { name: name, occurrences: occurrences }
        else
          needs_review << { name: name, occurrences: occurrences, reason: 'only appears in a shared/compound selector - remove manually' }
        end
      end

      deleted = delete ? delete_unused!(unused) : []
      normalize_blank_lines!(scss_files) if delete
      write_report(unused: unused, needs_review: needs_review, excluded_vendor: excluded_vendor, deleted: deleted, deleted_mode: delete)
    end

    private

    attr_reader :config

    # These files style markup rendered by third-party JS libraries (flatpickr,
    # turbolinks, tippy/tlite, dragula, etc.) - those classes are injected at
    # runtime by vendor code we don't scan, so never treat them as unused.
    def vendor_override_file?(file)
      config.vendor_override_filenames.include?(File.basename(file))
    end

    def scss_files
      Dir.glob(File.join(config.stylesheets_dir, '**/*.scss')).sort
    end

    def ruby_and_js_files
      corpus_files.select { |f| f.end_with?('.rb', '.erb', '.js') }
    end

    def corpus_files
      files = config.usage_globs.flat_map { |glob| Dir.glob(glob) }
      files.reject { |f| config.excluded_path_fragments.any? { |frag| f.include?(frag) } }.uniq
    end

    # Some npm packages (intl-tel-input, tippy.js, dragula, flatpickr, etc.)
    # inject their own classes into the DOM at runtime; those never appear as
    # literal strings in our own source, but do appear in the package's code.
    def build_vendor_token_counts
      counts = Hash.new(0)
      vendor_files.each do |file|
        content = begin
          File.read(file, encoding: 'UTF-8')
        rescue StandardError
          next
        end
        content.scan(/[A-Za-z0-9_-]+/) { |token| counts[token] += 1 }
      end
      counts
    end

    def vendor_files
      package_json = File.join(config.root, 'package.json')
      return [] unless File.exist?(package_json)

      deps = JSON.parse(File.read(package_json))['dependencies'] || {}
      deps.keys.flat_map do |name|
        dep_dir = File.join(config.root, 'node_modules', name)
        next [] unless Dir.exist?(dep_dir)

        Dir.glob(File.join(dep_dir, '**/*.{js,css,scss,ts}')).reject { |f| f.end_with?('.map') }
      end
    end

    def build_token_counts
      counts = Hash.new(0)
      corpus_files.each do |file|
        content = begin
          File.read(file, encoding: 'UTF-8')
        rescue StandardError
          next
        end
        content.scan(/[A-Za-z0-9_-]+/) { |token| counts[token] += 1 }
      end
      counts
    end

    # Collects static text immediately touching string interpolation
    # (Ruby "#{...}" / JS template literals "${...}") so that classes only
    # ever spelled out dynamically (e.g. "icon_#{name}") aren't deleted.
    def collect_dynamic_fragments(files)
      prefixes = Set.new
      suffixes = Set.new

      files.each do |file|
        content = begin
          File.read(file, encoding: 'UTF-8')
        rescue StandardError
          next
        end

        content.scan(/([A-Za-z0-9_-]{4,})#\{[^{}]*\}/) { |(frag)| prefixes << frag }
        content.scan(/#\{[^{}]*\}([A-Za-z0-9_-]{4,})/) { |(frag)| suffixes << frag }
        content.scan(/([A-Za-z0-9_-]{4,})\$\{[^{}]*\}/) { |(frag)| prefixes << frag }
        content.scan(/\$\{[^{}]*\}([A-Za-z0-9_-]{4,})/) { |(frag)| suffixes << frag }
      end

      { prefixes: prefixes, suffixes: suffixes }
    end

    def delete_unused!(unused)
      deletions_by_file = Hash.new { |h, k| h[k] = [] }
      deleted = []

      unused.each do |entry|
        entry[:occurrences].each do |occ|
          next unless occ[:exclusive]

          deletions_by_file[occ[:file]] << { name: entry[:name], line: occ[:line] }
        end
      end

      deletions_by_file.each do |file, occs|
        lines = File.readlines(file, encoding: 'UTF-8')
        raw_ranges = occs.map do |o|
          open_idx = o[:line] - 1
          { name: o[:name], range: open_idx..block_end_index(lines, open_idx) }
        end

        # A class nested inside another deleted class (e.g. .logo-loader inside
        # .ar-loading) produces a range fully contained in its parent's range.
        # Merge these so each line is only ever removed once, with correct offsets.
        merge_ranges(raw_ranges).each do |merged|
          lines.slice!(merged[:range])
          deleted << { name: merged[:names].join(', '), file: file, line: merged[:range].begin + 1 }
        end

        collapse_consecutive_blank_lines!(lines)
        File.write(file, lines.join)
      end

      deleted
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

    # Runs across every file in scope (not just ones with a deletion this run),
    # since double blank lines can pre-exist independently of this scanner.
    def normalize_blank_lines!(files)
      files.each do |file|
        lines = File.readlines(file, encoding: 'UTF-8')
        original_size = lines.size
        collapse_consecutive_blank_lines!(lines)
        File.write(file, lines.join) if lines.size != original_size
      end
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

    def block_end_index(lines, open_idx)
      depth = 0
      (open_idx...lines.size).each do |i|
        depth += lines[i].count('{') - lines[i].count('}')
        return i if depth <= 0
      end
      lines.size - 1
    end

    def write_report(unused:, needs_review:, excluded_vendor:, deleted:, deleted_mode:)
      lines = []
      lines << "# Unused CSS class report (#{Time.now})"
      lines << ''
      lines << "Mode: #{deleted_mode ? 'DELETE (high-confidence unused classes removed)' : 'DRY RUN (no files modified)'}"
      lines << ''
      lines << "== Deleted classes (#{deleted.size}) ==" if deleted_mode
      deleted.each { |d| lines << "  .#{d[:name]}  #{relative(d[:file])}:#{d[:line]}" } if deleted_mode
      lines << ''

      remaining_unused = deleted_mode ? [] : unused
      lines << "== Unused, high confidence (#{remaining_unused.size}) =="
      remaining_unused.each do |u|
        locations = u[:occurrences].map { |o| "#{relative(o[:file])}:#{o[:line]}" }.join(', ')
        lines << "  .#{u[:name]}  (#{locations})"
      end
      lines << ''

      lines << "== Needs manual review (#{needs_review.size}) =="
      needs_review.each do |nr|
        locations = nr[:occurrences].map { |o| "#{relative(o[:file])}:#{o[:line]}" }.join(', ')
        lines << "  .#{nr[:name]}  (#{locations}) - #{nr[:reason]}"
      end
      lines << ''

      lines << "== Excluded, vendor/plugin-override stylesheets (#{excluded_vendor.size}) =="
      excluded_vendor.each do |ev|
        locations = ev[:occurrences].map { |o| "#{relative(o[:file])}:#{o[:line]}" }.join(', ')
        lines << "  .#{ev[:name]}  (#{locations})"
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
