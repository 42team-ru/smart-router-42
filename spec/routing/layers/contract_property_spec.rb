# frozen_string_literal: true

require 'routing/layers'
require 'routing/layer_stack'
require 'routing/share_ledger'

# T-5. «Случайные конфигурации» здесь — это случайные допущенные наборы
# кандидатов, а не порядок самих слоёв в конфиге (тот покрыт тестами
# Assembly/CFG). Сид фиксирован ради воспроизводимости диагностики при
# падении; на файлы в spec/ запрет rand/shuffle/sample из
# scripts/check_determinism.sh не распространяется — он ограничен lib/routing
# и lib/execution.
#
# Routing::Layers.known.each ниже выполняется в момент ЗАГРУЗКИ этого файла
# (RSpec строит describe-блоки сразу, не откладывает до запуска примеров),
# поэтому load_all! обязан стоять здесь, на верхнем уровне, ДО цикла — вызов
# из before было бы поздно: проверено запуском, что без этого в одиночном
# прогоне файла получается 0 примеров, а в прогоне всего spec/routing
# тестируется только тот слой, чей файл к этому моменту случайно успел
# требоваться другим спеком раньше по алфавиту/порядку файлов.
Routing::Layers.load_all!

RSpec.describe 'все зарегистрированные слои' do
  include ProviderFactory

  let(:pool) do
    [build_provider(payment_system: 'vipay'),
     build_provider(payment_system: 'payflow'),
     build_provider(payment_system: 'quickpay'),
     build_provider(payment_system: 'spacepayments')]
  end

  Routing::Layers.known.each do |layer_name|
    describe layer_name do
      subject(:layer) { Routing::Layers.build(layer_name) }

      it 'зарегистрировано под именем, которое возвращает #name' do
        expect(layer.name).to eq(layer_name)
      end

      it 'на случайных допущенных наборах не добавляет и не убирает кандидатов' do
        assert_preserves_candidates(layer, pool)
      end

      it 'deviation — целое неотрицательное число на любом допущенном наборе' do
        assert_nonnegative_integer_deviation(layer, pool)
      end
    end
  end

  describe 'стопки из известных слоёв (обе перестановки)' do
    let(:known) { Routing::Layers.known }

    it 'сохраняют набор кандидатов при любом порядке слоёв в стопке' do
      known.permutation(known.size).each do |order|
        stack = Routing::LayerStack.new(order.map { |name| Routing::Layers.build(name) })

        assert_preserves_candidates(stack, pool)
      end
    end
  end

  def assert_preserves_candidates(layer, pool)
    rng = Random.new(20_260_904)

    200.times do
      candidates = pool.sample(rng.rand(pool.size + 1), random: rng)
      adjusted = layer.adjust(candidates, build_operation, Routing::ShareLedger.new)

      expect(adjusted.map(&:name)).to match_array(candidates.map(&:name))
    end
  end

  def assert_nonnegative_integer_deviation(layer, pool)
    rng = Random.new(20_260_904)
    state = Routing::ShareLedger.new

    200.times do
      candidates = pool.sample(rng.rand(pool.size) + 1, random: rng)
      candidates.each { |candidate| expect_nonnegative_integer(layer, candidate, state) }
    end
  end

  def expect_nonnegative_integer(layer, candidate, state)
    value = layer.deviation(candidate, build_operation, state)

    expect(value).to be_a(Integer)
    expect(value).to be >= 0
  end
end
