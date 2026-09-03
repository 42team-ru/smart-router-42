# frozen_string_literal: true

require 'rspec/core/rake_task'
require 'rubocop/rake_task'

RSpec::Core::RakeTask.new(:spec)
RuboCop::RakeTask.new(:rubocop)

QUEUE_PATH = 'reference/data/operations_queue_10.json'
DECISIONS_PATH = 'out/routing_decisions_test.json'

# T-1 нарочно не шеллится (sh "bundle exec bin/route ...") — на Windows это
# запускает bundle.bat через cmd.exe, а cmd.exe не умеет UNC как рабочую
# директорию (наш checkout может лежать на \\wsl.localhost\...). `load` в
# том же процессе работает независимо от ОС и обходится без подпроцесса.
desc 'T-1: bin/route на публичной очереди + validate_10.rb организаторов'
task :validate do
  root = __dir__
  load File.join(root, 'bin/route')
  main([File.join(root, QUEUE_PATH)])

  saved_argv = ARGV.dup
  ARGV.replace([File.join(root, DECISIONS_PATH)])
  begin
    load File.join(root, 'reference/scripts/validate_10.rb')
  rescue SystemExit => e
    raise "validate_10.rb нашёл ошибки (exit #{e.status})" unless e.status.zero?
  ensure
    ARGV.replace(saved_argv)
  end
end

task default: %i[spec rubocop]
