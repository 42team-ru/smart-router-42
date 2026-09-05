# frozen_string_literal: true

require 'json'
require 'config/loader'
require 'io/history_loader'
require 'io/provider_overrides'
require 'io/providers_loader'
require 'io/queue_loader'
require 'offline/comparison'
require 'routing/layers'
require 'routing/strategies'

# Офлайн-сравнение конфигураций. Спек намеренно работает на РЕАЛЬНОМ боевом
# конфиге/снапшоте/очереди -- иначе "совпадение с фактом" осталось бы
# утверждением без проверки. routing_report_test.json/routing_decisions_test.json в корне
# репозитория -- уже посчитанный факт (make deliver), decisions на публичной
# очереди этот пакет не меняет (spec/bin/route_spec.rb это стережёт отдельно).
# rubocop:disable RSpec/MultipleMemoizedHelpers -- реальный конфиг тянет реальные
# зависимости (провайдеры, очередь, история), меньше не выходит без потери
# "реальности" сценария.
# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations -- сверка с
# фактическим прогоном требует прочитать оба корневых JSON и посчитать оба
# ожидаемых числа рядом, дробить — терять контекст сравнения.
RSpec.describe Offline::Comparison do
  before do
    Routing::Strategies.load_all!
    Routing::Layers.load_all!
  end

  let(:root) { File.expand_path('../..', __dir__) }
  let(:config) { Config::Loader.load(File.join(root, 'config', 'routing.yml')) }
  let(:raw_providers) { Io::ProvidersLoader.load(File.join(root, 'data', 'providers.json')) }
  let(:providers) do
    Io::ProviderOverrides.apply(raw_providers, obligations: config.obligations,
                                               rate_limits: config.rate_limits)
  end
  let(:operations) { Io::QueueLoader.load(reference_path('operations_queue_10.json')).operations }
  let(:history) { Io::HistoryLoader.load(reference_path('operations_history.csv')) }

  def build(variants: config.comparison, baseline: 'count_share')
    described_class.build(variants: variants, operations: operations, providers: providers,
                          config: config, history: history, baseline: baseline)
  end

  it 'вариант с боевыми параметрами совпадает с метриками фактического прогона' do
    report = JSON.parse(File.read(File.join(root, 'routing_report_test.json')))
    decisions = JSON.parse(File.read(File.join(root, 'routing_decisions_test.json')))
    expected_delivered = decisions.count { |decision| decision['simulated_result'] != 'rejected' }
    expected_max_deviation = report.fetch('distribution').values.map do |entry|
      entry.fetch('deviation_pp').abs
    end.max

    baseline_metrics = build.fetch('variants').fetch('count_share')

    expect(baseline_metrics['delivered']).to eq(expected_delivered)
    expect(baseline_metrics['max_deviation_pp']).to eq(expected_max_deviation)
  end

  it 'два вызова подряд на одних входах дают идентичный результат' do
    first = build
    second = build

    expect(second).to eq(first)
  end

  it 'порядок вариантов в отчёте равен порядку вариантов в конфиге' do
    expect(build.fetch('variants').keys).to eq(config.comparison.map { |variant| variant['name'] })
  end

  it 'метрики варианта не зависят от того, каким по счёту он идёт в списке' do
    forward = build(variants: config.comparison)
    backward = build(variants: config.comparison.reverse)

    expect(backward.fetch('variants')).to eq(forward.fetch('variants'))
  end

  it 'round_robin и count_share дают различимые метрики' do
    variants = build.fetch('variants')

    expect(variants.fetch('round_robin')).not_to eq(variants.fetch('count_share'))
  end

  it 'baseline в результате -- переданное имя, а не домысленное' do
    expect(build.fetch('baseline')).to eq('count_share')
  end

  it 'metrics каждого варианта содержат ровно контрактные ключи' do
    build.fetch('variants').each_value do |metrics|
      expect(metrics.keys).to contain_exactly(
        'delivered', 'fallback_used', 'retried', 'max_deviation_pp', 'max_deviation_from_target_pp'
      )
    end
  end
end
# rubocop:enable RSpec/MultipleMemoizedHelpers
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
