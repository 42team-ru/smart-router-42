# frozen_string_literal: true

require 'json'
require 'open3'
require 'tmpdir'
require 'config/loader'
require 'io/providers_loader'
require 'routing/assembly'
require 'routing/layers/budget_headroom'
require 'routing/layers/share_ceiling'
require 'routing/share_ledger'
require_relative '../../support/provider_factory'

RSpec.describe 'лексикографический порядок слоёв' do
  include ProviderFactory

  let(:queue_path) { reference_path('operations_queue_10.json') }
  let(:bin_route) { File.expand_path('../../../bin/route', __dir__) }
  let(:providers) { Io::ProvidersLoader.load(reference_path('providers.json')) }

  # rubocop:disable-next RSpec/ExampleLength, RSpec/MultipleExpectations -- один контракт сравнивает оба порядка целей.
  it 'на op_110 меняет выбор при перестановке целей, не нарушая старшую цель' do
    adwords = run_configuration('adwords.yml')
    reversed = run_configuration('goals_reversed.yml')

    expect([adwords.fetch(:selected), reversed.fetch(:selected)]).to eq(%w[quickpay payflow])
    expect(adwords.fetch(:details)).to include('ниже порога 0.100 на 0.067', 'превышение 1945 bp')
    expected = ['максимальное превышение 1945 bp', 'минимальный psi 0.033']
    expect(reversed.fetch(:details)).to include(*expected)
    expect(senior_deviation(adwords, 'quickpay')).to be <= senior_deviation(adwords, 'payflow')
    expect(senior_deviation(reversed, 'payflow')).to be <= senior_deviation(reversed, 'quickpay')
  end

  private

  def run_configuration(filename)
    path = File.expand_path("../../../config/examples/#{filename}", __dir__)
    config = Config::Loader.load(path)
    layers = Routing::Assembly.layers(config: config)
    decision = selected_decision(path)

    { selected: decision.fetch('selected_provider'), details: decision.fetch(:details),
      layer: layers.first, state: op_110_state }
  end

  def selected_decision(config_path)
    Dir.mktmpdir do |dir|
      _stdout, stderr, status = Open3.capture3(
        'ruby', bin_route, queue_path, '--config', config_path, '--out-dir', dir
      )
      raise "bin/route упал: #{stderr}" unless status.success?

      decision_details(File.join(dir, 'routing_decisions_test.json'))
    end
  end

  def decision_details(path)
    decisions = JSON.parse(File.read(path))
    decision = decisions.find { |item| item.fetch('operation_id') == 'op_110' }
    attempt = decision.fetch('attempts').find { |item| item.fetch('decision') == 'selected' }
    { 'selected_provider' => decision.fetch('selected_provider'),
      details: attempt.fetch('details') }
  end

  def senior_deviation(result, provider_name)
    provider = providers.find { |item| item.name == provider_name }
    operation = build_operation(operation_id: 'op_110')
    result.fetch(:layer).deviation(provider, operation, result.fetch(:state))
  end

  def op_110_state
    state = Routing::ShareLedger.new
    counts = { 'quickpay' => 3, 'payflow' => 1, 'vipay' => 3 }
    counts.each do |provider_name, count|
      provider = providers.find { |item| item.name == provider_name }
      count.times do |index|
        operation = build_operation(operation_id: "#{provider_name}_#{index}")
        state.reserve(provider, operation).commit(provider, operation)
      end
    end
    state
  end
end
