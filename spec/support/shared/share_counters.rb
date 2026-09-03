# frozen_string_literal: true

RSpec.shared_examples 'счётчики долей' do
  let(:operation) { build_operation(amount: 15_000) }

  # rubocop:disable-next RSpec/MultipleExpectations
  it 'начинается с целых нулей' do
    expect(subject.count_units('unknown')).to be_a(Integer).and eq(0)
    expect(subject.volume_units('unknown')).to be_a(Integer).and eq(0)
    expect(subject.total_count_units).to be_a(Integer).and eq(0)
    expect(subject.total_volume_units).to be_a(Integer).and eq(0)
  end

  # rubocop:disable-next RSpec/MultipleExpectations
  it 'резервирует count и volume' do
    subject.reserve('vipay', operation)

    expect(subject.count_units('vipay')).to eq(1)
    expect(subject.volume_units('vipay')).to eq(15_000)
    expect(subject.total_count_units).to eq(1)
    expect(subject.total_volume_units).to eq(15_000)
  end

  # rubocop:disable-next RSpec/MultipleExpectations
  it 'commit закрывает резерв без изменения доли' do
    subject.reserve('vipay', operation).commit('vipay', operation)

    expect(subject.count_units('vipay')).to eq(1)
    expect(subject.open_reservations).to eq(0)
  end

  # rubocop:disable-next RSpec/MultipleExpectations
  it 'rollback полностью возвращает счётчики' do
    subject.reserve('vipay', operation).rollback('vipay', operation)

    expect(subject.total_count_units).to eq(0)
    expect(subject.total_volume_units).to eq(0)
    expect(subject.open_reservations).to eq(0)
  end

  it 'hold держит резерв' do
    subject.reserve('vipay', operation).hold('vipay', operation)

    expect(subject.open_reservations).to eq(1)
  end
end
