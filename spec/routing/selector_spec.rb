# frozen_string_literal: true

require 'json'
require 'open3'
require 'tmpdir'
require 'config/loader'
require 'config/routing_config'
require 'routing/assembly'
require 'routing/planner'
require 'routing/selector'
require 'routing/share_ledger'
require 'routing/strategies/amount_range'
require 'routing/strategies/conversion'
require 'routing/strategies/count_share'
require 'routing/strategies/load'
require 'routing/strategies/obligations'
require 'routing/strategies/priority'
require 'routing/strategies/volume_share'
require_relative '../support/provider_factory'

# rubocop:disable-next RSpec/MultipleMemoizedHelpers -- общие объекты отражают контракт Selector.
RSpec.describe Routing::Selector do
  include ProviderFactory

  let(:count_share) { Routing::Strategies.build('count_share') }
  let(:priority) { Routing::Strategies.build('priority') }
  let(:volume_share) { Routing::Strategies.build('volume_share') }
  let(:operation) { build_operation(amount: 40_000, bank: 'alfa') }
  let(:one_candidate) { [build_provider(payment_system: 'payflow')] }
  let(:two_candidates) { one_candidate + [build_provider(payment_system: 'quickpay')] }
  let(:state) { Routing::ShareLedger.new }

  before { Routing::Strategies.load_all! }

  it 'Static всегда возвращает одну стратегию с числом в details' do
    choice = described_class::Static.new(priority).call(two_candidates, operation, state)

    expect(choice).to have_attributes(strategy: priority, rule_index: nil, details: /1 стратегия/)
  end

  # rubocop:disable-next RSpec/ExampleLength, RSpec/MultipleExpectations -- граница и приоритет проверяются вместе.
  it 'срабатывает на границе amount_gte и берёт первое совпавшее правило' do
    selector = rules_selector(
      [{ 'when' => { 'amount_gte' => 40_000 }, 'use' => 'volume_share' },
       { 'when' => { 'amount_gte' => 1 }, 'use' => 'priority' }]
    )

    choice = selector.call(two_candidates, operation, state)

    expect(choice.rule_index).to eq(1)
    expect(choice.strategy).to be_a(Routing::Strategies::VolumeShare)
    expect(choice.details).to include('amount 40000 >= 40000', 'правило #1')
  end

  # rubocop:disable-next RSpec/MultipleExpectations -- один default-выбор и его объяснение.
  it 'возвращает default и число операции, когда правила не совпали' do
    selector = rules_selector([{ 'when' => { 'amount_gte' => 40_001 }, 'use' => 'priority' }])

    choice = selector.call(two_candidates, operation, state)

    expect(choice).to have_attributes(strategy: count_share, rule_index: nil)
    expect(choice.details).to include('0 правил из 1', 'amount 40000 < 40001')
  end

  # rubocop:disable-next RSpec/MultipleExpectations -- граница предиката: один и два кандидата.
  it 'учитывает eligible_count_lte после допуска' do
    selector = rules_selector([{ 'when' => { 'eligible_count_lte' => 1 }, 'use' => 'priority' }])

    expect(selector.call(one_candidate, operation, state).strategy).to be_a(Routing::Strategies::Priority)
    expect(selector.call(two_candidates, operation, state).strategy).to be_a(Routing::Strategies::CountShare)
  end

  it 'отвергает неизвестный предикат с перечислением допустимых' do
    expect { rules_selector([{ 'when' => { 'amount_between' => [1, 2] }, 'use' => 'priority' }]) }
      .to raise_error(ArgumentError, /amount_between.*amount_gte.*eligible_count_lte/m)
  end

  it 'отвергает неизвестную стратегию use со списком известных' do
    expect { rules_selector([{ 'when' => { 'amount_gte' => 1 }, 'use' => 'нет_такой' }]) }
      .to raise_error(KeyError, /нет_такой.*count_share/m)
  end

  it 'отвергает Float в целочисленном пороге' do
    expect { rules_selector([{ 'when' => { 'amount_gte' => 1.5 }, 'use' => 'priority' }]) }
      .to raise_error(ArgumentError, /amount_gte.*Integer/m)
  end

  # rubocop:disable-next RSpec/MultipleExpectations -- оба варианта статического селектора.
  it 'пустые strategy_selection и rules строят Static, default берёт config.strategy' do
    empty = Routing::Assembly.selector(config: config_with(selection: {}))
    no_rules_config = config_with(selection: { 'rules' => [] }, strategy: 'priority')
    no_rules = Routing::Assembly.selector(config: no_rules_config)

    expect(empty).to be_a(described_class::Static)
    expect(no_rules.call(two_candidates, operation, state).strategy).to be_a(Routing::Strategies::Priority)
  end

  # rubocop:disable-next RSpec/ExampleLength -- селектор-сторож и пустой план образуют один контракт.
  it 'не вызывает селектор для пустого каскада' do
    suspended = build_provider(payment_system: 'vipay', status: 'suspended')
    fallback = build_provider(payment_system: 'spacepayments')
    selector = Class.new do
      def call(*) = raise 'селектор не должен вызываться'
    end.new
    planner = Routing::Planner.new(providers: [suspended, fallback], selector: selector)

    expect(planner.plan(operation, state).trace).to be_nil
  end

  # rubocop:disable-next RSpec/MultipleExpectations -- сквозной контракт примера конфига.
  it 'на публичной очереди меняет хотя бы один выбор и проходит валидатор' do
    default = run_route(File.expand_path('../../config/routing.yml', __dir__))
    selected = run_route(File.expand_path('../../config/examples/selector.yml', __dir__))

    expect(selected.fetch(:validation)).to include('Ошибок:   0')
    expect(selected.fetch(:decisions).map { |item| item['selected_provider'] })
      .not_to eq(default.fetch(:decisions).map { |item| item['selected_provider'] })
  end

  # rubocop:disable-next RSpec/ExampleLength, RSpec/MultipleExpectations -- CLI-приоритет и trace проверяются вместе.
  it 'флаг --strategy отключает правила и оставляет соответствующий сегмент' do
    config_path = File.expand_path('../../config/examples/selector.yml', __dir__)
    result = run_route(config_path, '--strategy', 'priority')
    attempts = result.fetch(:decisions).flat_map { |decision| decision.fetch('attempts') }
    selected = attempts.select { |attempt| attempt['decision'] == 'selected' }

    expect(selected.map { |attempt| attempt['strategy'] }.compact.uniq).to eq(['priority'])
    expect(selected.map { |attempt| attempt['details'] }.compact.join(' | '))
      .to include('отключён флагом --strategy (1 источник) -> priority')
  end

  private

  def rules_selector(rules)
    built = rules.each_with_index.map do |rule, index|
      described_class::Rules::Rule.from_config(rule, index: index + 1, config: config_with)
    end
    described_class::Rules.new(default: count_share, rules: built)
  end

  def config_with(selection: {}, strategy: 'count_share')
    Config::RoutingConfig.new(
      strategy: strategy, layers: [], goals: {}, strategy_selection: selection, outcomes: {},
      amount_ranges: [], obligations: {}, rate_limits: {}, fallback_provider: 'spacepayments'
    )
  end

  def run_route(config_path, *arguments)
    Dir.mktmpdir do |dir|
      _stdout, stderr, status = Open3.capture3(
        'ruby', bin_route, queue_path, '--config', config_path, '--out-dir', dir, *arguments
      )
      raise "bin/route упал: #{stderr}" unless status.success?

      decisions_path = File.join(dir, 'routing_decisions_test.json')
      validation, = Open3.capture2('ruby', validator_path, decisions_path)
      { decisions: JSON.parse(File.read(decisions_path)), validation: validation }
    end
  end

  def bin_route = File.expand_path('../../bin/route', __dir__)
  def queue_path = reference_path('operations_queue_10.json')
  def validator_path = File.expand_path('../../reference/scripts/validate_10.rb', __dir__)
end
