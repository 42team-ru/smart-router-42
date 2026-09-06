# frozen_string_literal: true

require 'io/history_loader'
require 'io/providers_loader'
require 'io/queue_loader'
require 'execution/outcome_source/deterministic'

module OfflineSpecHelpers
  def offline_context(seed: '42', queue: 'operations_queue_10.json')
    providers = Io::ProvidersLoader.load(reference_path('providers.json'))
    operations = Io::QueueLoader.load(reference_path(queue)).operations
    history = Io::HistoryLoader.load(reference_path('operations_history.csv'))
    outcomes = Execution::OutcomeSource::Deterministic.new(
      seed: seed, outcome_table: history.to_outcome_table
    )
    [providers, operations, outcomes]
  end
end

RSpec.configure { |config| config.include OfflineSpecHelpers }
