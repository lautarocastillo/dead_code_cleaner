# dead_code_cleaner

Rake tasks to find (and optionally delete) unused Ruby methods, CSS classes,
JS functions and view partials in a Rails app.

Detection is pattern-based (word/text search, brace/`end` counting) - not a
real parser/AST for any of the four languages involved. Always run without
`DELETE=true` first and spot-check the report (`tmp/unused_*_report.txt`)
before deleting anything.

## Install

Add to the target app's `Gemfile`:

```ruby
gem 'dead_code_cleaner', git: 'git@github.com:lautarocastillo/dead_code_cleaner.git'
```

Rake tasks are exposed automatically via a Railtie - no need to copy any
`.rake` file into the app.

## Tasks

```bash
# Ruby methods (def / define_method) anywhere under app/**/*.rb - replaces
# what used to be five separate scanners (controllers/helpers/models/
# searchers/services).
bundle exec rake unused:ruby_methods
DELETE=true bundle exec rake unused:ruby_methods

# scope to one directory instead of the whole app
DIR=app/models bundle exec rake unused:ruby_methods

# CSS classes under app/assets/stylesheets
bundle exec rake unused:css              # reports AND deletes high-confidence matches
DRY_RUN=true bundle exec rake unused:css # report only

# JS functions/methods under app/javascript
bundle exec rake unused:js
DELETE=true bundle exec rake unused:js

# ERB/Jbuilder partials under app/views
bundle exec rake unused:views
DELETE=true bundle exec rake unused:views

# everything at once (report-only / each task's default mode)
bundle exec rake unused:all
```

Each task writes a full report to `tmp/unused_<name>_report.txt` and also
prints it to stdout, with sections for high-confidence unused items, items
that need manual review (setters, dynamically-built names, shared CSS
selectors, Rails' implicit partial rendering convention, etc.), and anything
excluded from checks (framework-invoked names, vendor stylesheet overrides).

## Adjusting for a different app's conventions

The rake task in `lib/tasks/dead_code_cleaner.rake` builds a small `Config`
struct per scanner (glob patterns, excluded paths, names to always treat as
used). Edit the values there - directly in this gem, or by copying the task
file into the consuming app's `lib/tasks/` and requiring the scanner classes
instead of relying on the Railtie - if your app uses different directories,
template extensions (`.haml`, `.slim`, ...), or has extra reflectively
invoked method names (e.g. more Devise/Searchkick callbacks).
