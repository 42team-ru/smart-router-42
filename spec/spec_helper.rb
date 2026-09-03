# frozen_string_literal: true

SPEC_ROOT = __dir__

$LOAD_PATH.unshift(File.join(SPEC_ROOT, '..', 'lib'))

Dir[File.join(SPEC_ROOT, 'support', '**', '*.rb')].each { |f| require f }

RSpec.configure do |config|
  config.disable_monkey_patching!

  config.order = :defined
end

def fixture_path(*parts)
  File.join(SPEC_ROOT, 'fixtures', *parts)
end

def reference_path(*parts)
  File.join(SPEC_ROOT, '..', 'reference', 'data', *parts)
end
