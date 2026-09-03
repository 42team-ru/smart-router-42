# frozen_string_literal: true

require 'io/providers_loader'
require 'io/queue_loader'
require 'execution/executor'
require 'execution/outcome_source/always_ok'
require 'routing/planner'
require 'routing/share_ledger'
require 'routing/strategies/count_share'
require 'routing/strategies/volume_share'
require 'state/providers'

# rubocop:disable-next RSpec/MultipleExpectations, RSpec/DescribeMethod
RSpec.describe Routing::Strategies::VolumeShare, 'на публичной очереди' do
  let(:providers) { Io::ProvidersLoader.load(reference_path('providers.json')) }
  let(:operations) { Io::QueueLoader.load(reference_path('operations_queue_10.json')).operations }
  let(:strategy) { described_class.new }
  let(:planner) { Routing::Planner.new(providers: providers, strategy: strategy) }

  it 'воспроизводит траекторию DRR и итоговый объём' do
    run = route_with(strategy)

    expect(run.fetch(:before_op_103_quickpay_deficit)).to be >= 0
    expect(run.fetch(:at_op_105_quickpay_deficit)).to eq(-990_000_000)
    expect(run.fetch(:volumes)).to eq('vipay' => 102_000, 'payflow' => 88_800,
                                      'quickpay' => 195_000)
  end

  it 'после op_103 не отдаёт quickpay ни одну спорную операцию' do
    selected = route_with(strategy).fetch(:selected)
    disputed_after_forced_volume = %w[op_105 op_106 op_109 op_110]

    quickpay_wins = disputed_after_forced_volume.filter { |id| selected.fetch(id) == 'quickpay' }

    expect(quickpay_wins).to be_empty
  end

  # rubocop:disable-next RSpec/ExampleLength
  it 'оставляет четыре форсированные операции независимыми от стратегии' do
    volume = route_with(strategy)
    count = route_with(Routing::Strategies::CountShare.new)
    forced = %w[op_103 op_104 op_107 op_108]

    expect(forced.to_h do |id|
      [id, volume.fetch(:candidate_counts).fetch(id)]
    end.values).to all(eq(1))
    expect(forced.to_h { |id| [id, volume.fetch(:selected).fetch(id)] }).to eq(
      forced.to_h { |id| [id, count.fetch(:selected).fetch(id)] }
    )
  end

  # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength
  def route_with(active_strategy)
    active_planner = Routing::Planner.new(providers: providers, strategy: active_strategy)
    ledger = Routing::ShareLedger.new
    state = State::Providers.new(providers)
    executor = Execution::Executor.new(outcomes: Execution::OutcomeSource::AlwaysOk.new)
    selected = {}
    candidate_counts = {}
    before_op_103_quickpay_deficit = nil
    at_op_105_quickpay_deficit = nil

    operations.each do |operation|
      if operation.operation_id == 'op_103'
        before_op_103_quickpay_deficit = deficit('quickpay',
                                                 ledger)
      end
      at_op_105_quickpay_deficit = deficit('quickpay', ledger) if operation.operation_id == 'op_105'
      plan = active_planner.plan(operation, ledger)
      outcome = executor.run(plan, operation, state)
      provider = outcome.selected
      candidate_counts[operation.operation_id] = plan.candidates.size
      selected[operation.operation_id] = provider.name
      ledger.reserve(provider, operation).commit(provider, operation)
    end

    { selected: selected, candidate_counts: candidate_counts,
      before_op_103_quickpay_deficit: before_op_103_quickpay_deficit,
      at_op_105_quickpay_deficit: at_op_105_quickpay_deficit,
      volumes: volumes(ledger) }
  end

  def deficit(name, ledger)
    provider = providers.find { |item| item.name == name }
    target = provider.traffic_percentage * 100 * ledger.total_volume_units
    target - (10_000 * ledger.volume_units(name))
  end

  def volumes(ledger)
    %w[vipay payflow quickpay].to_h { |name| [name, ledger.volume_units(name)] }
  end
end
