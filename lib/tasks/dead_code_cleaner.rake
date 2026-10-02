# Rake tasks provided by the dead_code_cleaner gem. In a Rails app with the
# gem in the Gemfile, these load automatically via DeadCodeCleaner::Railtie.
# In a non-Rails app, `require 'dead_code_cleaner'` and `load` this file from
# your own Rakefile.
#
# Usage:
#   bundle exec rake unused:ruby_methods              # scans all of app/**/*.rb; report only
#   DELETE=true bundle exec rake unused:ruby_methods  # ALSO deletes high-confidence unused methods
#   DIR=app/models bundle exec rake unused:ruby_methods   # scope to one directory, e.g. just models
#
#   bundle exec rake unused:css               # reports AND deletes high-confidence unused classes
#   DRY_RUN=true bundle exec rake unused:css  # reports only
#
#   bundle exec rake unused:js                # report only
#   DELETE=true bundle exec rake unused:js    # ALSO deletes high-confidence unused functions
#
#   bundle exec rake unused:views             # report only
#   DELETE=true bundle exec rake unused:views # ALSO deletes high-confidence unused partial files
#
#   bundle exec rake unused:all               # runs all of the above (report-only / default modes)
namespace :unused do
  app_root = defined?(Rails) ? Rails.root.to_s : Dir.pwd

  # Methods invoked reflectively by Ruby/Rails/gems, or by the router,
  # rather than by their literal name anywhere in our own source. This is
  # the union of what used to be five separate per-directory lists
  # (controllers/helpers/models/searchers/services) - now that one task
  # scans all of them together, one shared list covers all cases.
  RUBY_METHODS_ALWAYS_USED_NAMES = %w[
    initialize to_s to_param inspect hash eql? as_json to_json serializable_hash
    method_missing respond_to_missing?
    index show new create edit update destroy root
    after_sign_in_path_for after_sign_out_path_for
    search_data should_index? use_relative_model_naming? password_required?
    find_for_database_authentication find_for_authentication
    active_for_authentication? inactive_message
    after_database_authentication send_devise_notification
  ].freeze

  desc 'Scan app/**/*.rb (or DIR=...) for unused methods; reports only unless DELETE=true'
  task :ruby_methods do
    dir = File.join(app_root, ENV['DIR'] || 'app')
    label = ENV['LABEL'] || (ENV['DIR'] ? File.basename(ENV['DIR']) : 'app')

    config = DeadCodeCleaner::RubyMethodScanner::Config.new(
      root: app_root,
      dir: dir,
      label: label,
      report_path: File.join(app_root, "tmp/unused_#{label}_methods_report.txt"),
      usage_globs: [
        File.join(app_root, 'app/**/*.{rb,erb,jbuilder,js}'),
        File.join(app_root, 'spec/**/*.rb'),
        File.join(app_root, 'config/routes.rb')
      ],
      excluded_path_fragments: ['/assets/builds/'],
      always_used_names: RUBY_METHODS_ALWAYS_USED_NAMES
    )
    DeadCodeCleaner::RubyMethodScanner.new(config).run(delete: ENV['DELETE'] == 'true')
  end

  desc 'Scan app/assets/stylesheets for unused CSS classes; deletes high-confidence ones unless DRY_RUN=true'
  task :css do
    config = DeadCodeCleaner::CssScanner::Config.new(
      root: app_root,
      stylesheets_dir: File.join(app_root, 'app/assets/stylesheets'),
      report_path: File.join(app_root, 'tmp/unused_css_report.txt'),
      usage_globs: [
        File.join(app_root, 'app/**/*.{rb,erb,js,scss}'),
        File.join(app_root, 'spec/**/*.rb'),
        File.join(app_root, 'config/locales/**/*.yml')
      ],
      excluded_path_fragments: ['/assets/builds/'],
      vendor_override_filenames: ['_plugin-overrides.scss']
    )
    DeadCodeCleaner::CssScanner.new(config).run(delete: ENV['DRY_RUN'] != 'true')
  end

  desc 'Scan app/javascript for unused JS functions/methods; reports only unless DELETE=true'
  task :js do
    config = DeadCodeCleaner::JsScanner::Config.new(
      root: app_root,
      js_dir: File.join(app_root, 'app/javascript'),
      report_path: File.join(app_root, 'tmp/unused_js_report.txt'),
      usage_globs: [File.join(app_root, 'app/javascript/**/*.js'), File.join(app_root, 'app/views/**/*.erb')],
      excluded_path_fragments: ['/assets/builds/'],
      always_used_names: %w[constructor onload]
    )
    DeadCodeCleaner::JsScanner.new(config).run(delete: ENV['DELETE'] == 'true')
  end

  desc 'Scan app/views for unused partials; reports only unless DELETE=true'
  task :views do
    config = DeadCodeCleaner::ViewScanner::Config.new(
      root: app_root,
      views_dir: File.join(app_root, 'app/views'),
      report_path: File.join(app_root, 'tmp/unused_views_report.txt'),
      usage_globs: [File.join(app_root, 'app/**/*.{rb,erb,jbuilder}'), File.join(app_root, 'spec/**/*.rb')],
      excluded_path_fragments: ['/assets/builds/']
    )
    DeadCodeCleaner::ViewScanner.new(config).run(delete: ENV['DELETE'] == 'true')
  end

  desc 'Run all unused-code scanners (ruby_methods, css, js, views)'
  task all: %i[ruby_methods css js views]
end
