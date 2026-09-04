# frozen_string_literal: true

require 'io/history_loader'
require 'io/providers_loader'
require 'io/queue_loader'
require 'execution/outcome_source/deterministic'

module OfflineSpecHelpers
  def offline_context(seed: '42', queue: 'operations_queue_10.json')
    providers = Io::ProvidersLoader.load(reference_path('providers.json'))
    operations = Io::QueueLoader.load(reference_path(queue)).operations
    outcomes = Execution::OutcomeSource::Deterministic.new(
      seed: seed, conversions: Io::HistoryLoader.load(reference_path('operations_history.csv'))
    )
    [providers, operations, outcomes]
  end
end

RSpec.configure { |config| config.include OfflineSpecHelpers }
