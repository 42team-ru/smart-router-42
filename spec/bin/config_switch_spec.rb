# frozen_string_literal: true

require 'json'
require 'open3'
require 'tmpdir'
require 'config/loader'
require 'routing/layers'
require 'routing/strategies'
require 'routing/strategies/amount_range'
require 'routing/strategies/conversion'
require 'routing/strategies/count_share'
require 'routing/strategies/load'
require 'routing/strategies/obligations'
require 'routing/strategies/priority'
require 'routing/strategies/volume_share'

# CFG-2: «смена одной строки меняет распределение, код не тронут».
#
# Числа измерены прогоном на reference/data/operations_queue_10.json с дефолтами
# bin/route (--outcomes deterministic --seed 42), а не выведены на бумаге.
# Расхождение здесь — сигнал, что сдвинулся seed, конверсии или reference/data,
# и таблицу надо перемерить, а не подогнать спек.
#
# rubocop:disable RSpec/DescribeClass -- сценарий CLI, а не класс
# rubocop:disable RSpec/MultipleExpectations -- один прогон проверяется набором
# связанных утверждений: распределение без details доказывает не то же самое
# rubocop:disable RSpec/ExampleLength -- каждый пример готовит временный конфиг,
# каталог и запускает отдельный процесс
RSpec.describe 'переключение поведения конфигом' do
  # Строки боевого YAML, которые подменяются, и измеренные распределения.
  def strategy_line = 'strategy: count_share'
  def payflow_band = '  - { from: 500, to: 50000, prefer: payflow }'
  def count_share_split = { 'vipay' => 4, 'payflow' => 3, 'quickpay' => 3 }
  def load_split = { 'payflow' => 1, 'quickpay' => 9 }
  def band_payflow_split = { 'vipay' => 3, 'payflow' => 3, 'quickpay' => 4 }
  def band_vipay_split = { 'vipay' => 4, 'payflow' => 3, 'quickpay' => 3 }

  let(:bin_route) { File.expand_path('../../bin/route', __dir__) }
  let(:queue_path) { reference_path('operations_queue_10.json') }
  let(:production_config) { File.expand_path('../../config/routing.yml', __dir__) }

  # Боевой config/routing.yml только читается: правка уходит во временный файл.
  # sub по конкретной строке, чтобы спек падал, если строка из YAML исчезла.
  def config_with(dir, replacements)
    source = File.read(production_config)
    replacements.each do |line, replacement|
      raise "строка #{line.inspect} исчезла из config/routing.yml" unless source.include?(line)

      source = source.sub(line, replacement)
    end
    path = File.join(dir, 'routing.yml')
    File.write(path, source)
    path
  end

  def decisions_for(dir, replacements)
    config = config_with(dir, replacements)
    _stdout, stderr, status = Open3.capture3('ruby', bin_route, queue_path,
                                             '--out-dir', dir, '--config', config)
    raise "bin/route упал: #{stderr}" unless status.exitstatus.zero?

    JSON.parse(File.read(File.join(dir, 'routing_decisions_test.json')))
  end

  def split(decisions)
    decisions.each_with_object(Hash.new(0)) { |d, acc| acc[d['selected_provider']] += 1 }
  end

  def op101(decisions) = decisions.find { |d| d['operation_id'] == 'op_101' }

  describe 'сценарий 1: строка strategy' do
    it 'strategy: count_share даёт 4/3/3' do
      Dir.mktmpdir do |tmp|
        decisions = decisions_for(tmp, { strategy_line => strategy_line })

        expect(split(decisions)).to eq(count_share_split)
      end
    end

    it 'strategy: load даёт 0/1/9 — распределение изменила одна строка YAML' do
      Dir.mktmpdir do |tmp|
        decisions = decisions_for(tmp, { strategy_line => 'strategy: load' })

        expect(split(decisions)).to eq(load_split)
        expect(split(decisions)['vipay']).to eq(0)
      end
    end
  end

  describe 'сценарий 2: строка данных, а не имя стратегии' do
    # Падает, если конфиг доехал только до выбора класса, а полосы остались
    # дефолтными (пустыми): тогда amount_range вырождается в priority.
    it 'полоса за payflow ставит payflow первым на op_101' do
      Dir.mktmpdir do |tmp|
        decisions = decisions_for(tmp, { strategy_line => 'strategy: amount_range' })

        expect(split(decisions)).to eq(band_payflow_split)
        expect(op101(decisions)['selected_provider']).to eq('payflow')
        expect(op101(decisions)['attempts'].first['details']).to include('полоса за payflow')
      end
    end

    it 'та же строка с prefer: vipay переставляет op_101 и распределение' do
      Dir.mktmpdir do |tmp|
        decisions = decisions_for(
          tmp,
          { strategy_line => 'strategy: amount_range',
            payflow_band => '  - { from: 500, to: 50000, prefer: vipay }' }
        )

        expect(split(decisions)).to eq(band_vipay_split)
        expect(op101(decisions)['selected_provider']).to eq('vipay')
        expect(op101(decisions)['attempts'].first['details']).to include('полоса за vipay')
      end
    end
  end

  describe 'сценарий 3: боевой конфиг непротиворечив' do
    let(:config) { Config::Loader.load(production_config) }

    it 'strategy из config/routing.yml есть в реестре стратегий' do
      expect(Routing::Strategies.known).to include(config.strategy)
    end

    it 'каждое имя из layers есть в реестре слоёв' do
      expect(config.layers - Routing::Layers.known).to eq([])
    end

    it 'fallback_provider остался spacepayments' do
      expect(config.fallback_provider).to eq('spacepayments')
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/ExampleLength
