module DeadCodeCleaner
  # Exposes lib/tasks/dead_code_cleaner.rake as `rake unused:*` tasks in any
  # Rails app that has this gem in its Gemfile - no manual copying required.
  class Railtie < ::Rails::Railtie
    rake_tasks do
      load File.expand_path('../tasks/dead_code_cleaner.rake', __dir__)
    end
  end
end
