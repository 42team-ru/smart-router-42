# frozen_string_literal: true

# Аналог 'контракт стратегии' (strategy_contract.rb) для слоёв Ф4 (X-1/X-2/X-3).
# Спек-контекст должен определить subject (экземпляр слоя), ranked (уже
# допущенные и отранжированные кандидаты — то, что слой реально видит в
# Planner#plan), operation и state (Routing::ShareLedger).
#
# Отличия от контракта стратегии — осознанные, не копипаста с недосмотром:
# - нет проверки независимости от порядка входа: стратегия ранжирует с нуля и
#   обязана её соблюдать, слой — наоборот, переставляет уже готовый порядок,
#   adjust(ranked.reverse, ...) не обязан совпадать с adjust(ranked, ...);
# - нет проверки Layers.build/Layers.known здесь: FakeLayer и BrokenFakeLayer*
#   (spec/support/fake_layer.rb) намеренно не зарегистрированы в
#   Routing::Layers, поэтому проверка регистрации живёт в
#   contract_property_spec.rb, который перебирает только реально
#   зарегистрированные слои. Здесь, симметрично strategy_contract.rb, только
#   то, что #name (теперь объявлен в Routing::Layers::Base) отдаёт непустую
#   строку — это верно и для боевых слоёв, и для фейков.
RSpec.shared_examples 'контракт слоя' do
  # rubocop:disable-next RSpec/MultipleExpectations
  it 'возвращает перестановку ranked и не мутирует входной массив' do
    before = ranked.dup
    adjusted = subject.adjust(ranked, operation, state)

    expect(adjusted.map(&:name)).to match_array(before.map(&:name))
    expect(adjusted.size).to eq(before.size)
    expect(ranked).to eq(before)
  end

  it 'не мутирует state' do
    before = state_snapshot

    subject.adjust(ranked, operation, state)

    expect(state_snapshot).to eq(before)
  end

  it 'обрабатывает пустой список кандидатов' do
    expect(subject.adjust([], operation, state)).to eq([])
  end

  it 'возвращает единственного кандидата' do
    expect(subject.adjust([ranked.first], operation, state)).to eq([ranked.first])
  end

  it 'детерминирован при повторном вызове на тех же данных' do
    first = subject.adjust(ranked, operation, state)
    repeated = subject.adjust(ranked, operation, state)

    expect(repeated).to eq(first)
  end

  # rubocop:disable-next RSpec/MultipleExpectations -- оба факта про одну строку.
  it 'имеет непустое имя' do
    expect(subject.name).to be_a(String)
    expect(subject.name).not_to be_empty
  end

  def state_snapshot
    ranked.to_h do |provider|
      [provider.name, [state.count_units(provider), state.volume_units(provider)]]
    end
  end
end
