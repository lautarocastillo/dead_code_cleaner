require 'dead_code_cleaner/version'
require 'dead_code_cleaner/ruby_method_scanner'
require 'dead_code_cleaner/css_scanner'
require 'dead_code_cleaner/js_scanner'
require 'dead_code_cleaner/view_scanner'
require 'dead_code_cleaner/railtie' if defined?(Rails::Railtie)

module DeadCodeCleaner
end
