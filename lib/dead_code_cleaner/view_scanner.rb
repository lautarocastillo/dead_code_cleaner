require 'set'
require 'fileutils'
begin
  require 'active_support/inflector'
rescue LoadError
  nil
end

module DeadCodeCleaner
  # Detects ERB/Jbuilder partials under a views directory (`_*.*` files) that
  # have no detectable `render`/`render_to_string`/`json.partial!` call
  # anywhere in the app (other views, layouts, controllers, mailers,
  # helpers, specs...).
  #
  # Only partials (filenames starting with `_`) are checked. Full templates
  # (`index.html.erb`, `show.html.erb`, etc.) are rendered implicitly by
  # Rails' controller-action convention and are out of scope here.
  #
  # Detection is pattern-based (word/text search), not a real ERB/Rails
  # parser, so:
  #   - a partial is counted as "used" if its `dir/name` (e.g.
  #     `surgeons/form`) OR its bare `name` (e.g. `form`, for same-directory
  #     relative `render 'form'` calls) appears as a literal render/partial
  #     argument anywhere in the app
  #   - partials whose name is the singular of their containing directory
  #     (e.g. `surgeons/_surgeon.html.erb`) match Rails' implicit
  #     object/collection rendering convention (`render @surgeon` /
  #     `render @surgeons`), which has no literal partial name to search for
  #     - these are sent to manual review instead of "unused"
  #   - partial names only ever built dynamically (e.g.
  #     `render "surgeons/forms/#{tab}"`) are sent to manual review instead
  #     of "unused"
  # Because deleting a partial means deleting the whole file (not a line
  # range), there's no "boundaries unclear, skip" case like the other
  # scanners - a flagged partial is either kept or removed whole.
  class ViewScanner
    Config = Struct.new(
      :root,                    # app root, used only to print relative paths in the report
      :views_dir,               # where view templates live
      :report_path,             # where to write the text report
      :usage_globs,             # glob(s) of source/template files to search for partial usage
      :excluded_path_fragments, # path fragments to exclude from usage scanning (build output)
      keyword_init: true
    )

    Partial = Struct.new(:path, :dir, :name, :full_ref, :bare_ref, :implicit_convention?, keyword_init: true)

    def initialize(config)
      @config = config
    end

    def run(delete:)
      partials = find_partials
      usage = scan_usage(corpus_files)
      dynamic_fragments = collect_dynamic_fragments(corpus_files)

      unused = []
      needs_review = []

      partials.each do |partial|
        if partial.implicit_convention?
          needs_review << { partial: partial,
                             reason: "matches Rails' implicit object/collection rendering convention (`render @#{partial.name}` / `render @#{partial.name}s`) - verify manually" }
          next
        end

        next if usage[:referenced].include?(partial.full_ref) || usage[:referenced].include?(partial.bare_ref) ||
                usage[:slash_literals].include?(partial.full_ref)

        if dynamic_fragments[:prefixes].any? { |frag| partial.full_ref.start_with?(frag) } ||
           dynamic_fragments[:suffixes].any? { |frag| partial.full_ref.end_with?(frag) }
          needs_review << { partial: partial,
                             reason: 'matches a dynamically-built partial name fragment (string interpolation) - verify manually' }
        else
          unused << { partial: partial }
        end
      end

      deleted = delete ? delete_unused!(unused) : []
      write_report(unused: unused, needs_review: needs_review, deleted: deleted, deleted_mode: delete)
    end

    private

    attr_reader :config

    def find_partials
      Dir.glob(File.join(config.views_dir, '**/_*.*')).sort.map { |path| build_partial(path) }
    end

    def build_partial(path)
      rel_path = path.sub(%r{\A#{Regexp.escape(config.views_dir)}/}, '')
      dir = File.dirname(rel_path)
      name = File.basename(rel_path).sub(/\A_/, '').split('.').first
      full_ref = dir == '.' ? name : "#{dir}/#{name}"
      last_dir_segment = dir == '.' ? nil : dir.split('/').last

      Partial.new(path: path, dir: dir, name: name, full_ref: full_ref, bare_ref: name,
                  implicit_convention?: last_dir_segment && singularize(last_dir_segment) == name)
    end

    def singularize(word)
      if defined?(ActiveSupport::Inflector)
        ActiveSupport::Inflector.singularize(word)
      else
        word.sub(/s\z/, '')
      end
    end

    def corpus_files
      files = config.usage_globs.flat_map { |glob| Dir.glob(glob) }
      files.reject { |f| config.excluded_path_fragments.any? { |frag| f.include?(frag) } }.uniq
    end

    # Extracts every string literal passed as a partial name to `render`,
    # `render_to_string` or Jbuilder's `partial!`, across the whole file
    # content (not line-by-line), so calls whose hash args wrap onto multiple
    # lines are still matched.
    def scan_usage(files)
      referenced = Set.new
      slash_literals = Set.new

      files.each do |file|
        content = begin
          File.read(file, encoding: 'UTF-8')
        rescue StandardError
          next
        end

        content.scan(/partial:\s*["']([^"']+)["']/) { |(name)| referenced << normalize_ref(name) }
        content.scan(/:partial\s*=>\s*["']([^"']+)["']/) { |(name)| referenced << normalize_ref(name) }
        content.scan(/partial!\s*\(?\s*["']([^"']+)["']/) { |(name)| referenced << normalize_ref(name) }
        content.scan(/render(?:_to_string)?\s*\(?\s*["']([^"']+)["']/) { |(name)| referenced << normalize_ref(name) }
        # Catches a partial name assigned to a variable before being passed to `render partial: var`
        # (e.g. `partial = cond ? 'dashboards/a' : 'dashboards/b'; render partial: partial`), where the
        # literal isn't textually adjacent to `render`/`partial:` anymore.
        content.scan(%r{["'](\w+(?:/\w+)+)["']}) { |(name)| slash_literals << normalize_ref(name) }
      end

      { referenced: referenced, slash_literals: slash_literals }
    end

    def normalize_ref(name)
      name.sub(%r{\A/}, '').sub(/\.(json|html|js|text|xml|csv)\z/, '')
    end

    # Collects static text immediately touching string interpolation
    # (`#{...}`), including path separators, so that partial names only ever
    # built dynamically (e.g. `render "surgeons/forms/#{tab}"`) aren't
    # flagged as unused.
    def collect_dynamic_fragments(files)
      prefixes = Set.new
      suffixes = Set.new

      files.each do |file|
        content = begin
          File.read(file, encoding: 'UTF-8')
        rescue StandardError
          next
        end

        content.scan(%r{([A-Za-z0-9_/]{3,})#\{[^{}]*\}}) { |(frag)| prefixes << frag }
        content.scan(%r{#\{[^{}]*\}([A-Za-z0-9_/]{3,})}) { |(frag)| suffixes << frag }
      end

      { prefixes: prefixes, suffixes: suffixes }
    end

    def delete_unused!(unused)
      unused.map do |entry|
        path = entry[:partial].path
        File.delete(path)
        path
      end
    end

    def write_report(unused:, needs_review:, deleted:, deleted_mode:)
      lines = []
      lines << "# Unused view partial report (#{Time.now})"
      lines << ''
      lines << "Mode: #{deleted_mode ? 'DELETE (high-confidence unused partials removed)' : 'DRY RUN (no files modified)'}"
      lines << ''

      if deleted_mode
        lines << "== Deleted partials (#{deleted.size}) =="
        deleted.each { |path| lines << "  #{relative(path)}" }
        lines << ''
      end

      remaining_unused = deleted_mode ? [] : unused
      lines << "== Unused, high confidence (#{remaining_unused.size}) =="
      remaining_unused.each do |u|
        lines << "  #{relative(u[:partial].path)}  (referenced as: #{u[:partial].full_ref})"
      end
      lines << ''

      lines << "== Needs manual review (#{needs_review.size}) =="
      needs_review.each do |nr|
        lines << "  #{relative(nr[:partial].path)}  (referenced as: #{nr[:partial].full_ref}) - #{nr[:reason]}"
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
