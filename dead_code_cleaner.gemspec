require_relative 'lib/dead_code_cleaner/version'

Gem::Specification.new do |spec|
  spec.name        = 'dead_code_cleaner'
  spec.version     = DeadCodeCleaner::VERSION
  spec.authors     = ['Lautaro Castillo']
  spec.email       = ['lautarocastillo.93@gmail.com']
  spec.summary     = 'Rake tasks to find (and optionally delete) unused Ruby methods, CSS classes, ' \
                      'JS functions and view partials in a Rails app.'
  spec.description = spec.summary
  spec.homepage    = 'https://github.com/lautarocastillo/dead_code_cleaner'
  spec.license     = 'MIT'

  spec.files         = Dir['lib/**/*', 'README.md']
  spec.require_paths = ['lib']
  spec.required_ruby_version = '>= 2.7'

  spec.add_dependency 'rake', '>= 12.0'

  spec.add_development_dependency 'rails', '>= 6.0'
end
