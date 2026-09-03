# frozen_string_literal: true

RSpec.shared_examples 'контракт стратегии' do
  # rubocop:disable-next RSpec/MultipleExpectations
  it 'возвращает перестановку кандидатов и не мутирует входной массив' do
    before = candidates.dup
    ranked = subject.rank(candidates, operation, state)

    expect(ranked.map(&:name)).to match_array(before.map(&:name))
    expect(ranked.size).to eq(before.size)
    expect(candidates).to eq(before)
  end

  it 'не мутирует состояние' do
    before = state_snapshot

    subject.rank(candidates, operation, state)

    expect(state_snapshot).to eq(before)
  end

  it 'обрабатывает пустой список кандидатов' do
    expect(subject.rank([], operation, state)).to eq([])
  end

  it 'возвращает единственного кандидата' do
    expect(subject.rank([candidates.first], operation, state)).to eq([candidates.first])
  end

  # rubocop:disable-next RSpec/MultipleExpectations
  it 'детерминирован и не зависит от порядка входа' do
    first = subject.rank(candidates, operation, state)
    repeated = subject.rank(candidates, operation, state)
    reversed = subject.rank(candidates.reverse, operation, state)

    expect(repeated).to eq(first)
    expect(reversed).to eq(first)
  end

  # rubocop:disable-next RSpec/MultipleExpectations
  it 'имеет зарегистрированное непустое имя' do
    expect(subject.name).to be_a(String)
    expect(subject.name).not_to be_empty
    expect(Routing::Strategies.known).to include(subject.name)
    expect(Routing::Strategies.build(subject.name)).to be_a(subject.class)
  end

  it 'объясняет порядок числом' do
    ranked = subject.rank(candidates, operation, state)

    expect(subject.explain(ranked, operation, state)).to be_a(String).and match(/\d/)
  end

  def state_snapshot
    candidates.to_h do |provider|
      [provider.name, [state.count_units(provider), state.volume_units(provider)]]
    end
  end
end
