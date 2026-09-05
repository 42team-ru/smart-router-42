# frozen_string_literal: true

require 'io/providers_loader'
require 'routing/layers/budget_headroom'
require 'state/providers'
require_relative '../../support/provider_factory'

# rubocop:disable-next RSpec/MultipleExpectations, RSpec/ExampleLength -- числа X-2 образуют один контракт.
RSpec.describe Routing::Layers::BudgetHeadroom do
  include ProviderFactory

  let(:providers) { Io::ProvidersLoader.load(reference_path('providers.json')) }
  let(:by_name) { providers.to_h { |provider| [provider.name, provider] } }
  let(:layer) { described_class.new }

  it 'считает числа приёмки X-2 и форматирует их без float' do
    results = %w[quickpay vipay payflow].to_h do |name|
      psi = layer.psi_micro(by_name.fetch(name), nil)
      [name, [psi, layer.send(:format_micro, psi)]]
    end

    expect(results).to eq(
      'quickpay' => [577_895, '0.578'],
      'vipay' => [302_324, '0.302'],
      'payflow' => [32_784, '0.033']
    )
  end

  it 'считает deviation при пороге 90% израсходованного лимита' do
    deviations = %w[payflow vipay quickpay].to_h do |name|
      [name, layer.deviation(by_name.fetch(name), build_operation, nil)]
    end

    # Порог 90% = psi 0.095; payflow потратил 96.7% (psi 0.033) и отстаёт на
    # 0.062, у остальных запас есть.
    expect(deviations).to eq('payflow' => 62_379, 'vipay' => 0, 'quickpay' => 0)
  end

  it 'обрабатывает T=0, T=1 и перерасход' do
    zero = build_provider(daily_approved_amount: 0, daily_amount_limit: 100)
    full = build_provider(daily_approved_amount: 100, daily_amount_limit: 100)
    over = build_provider(daily_approved_amount: 101, daily_amount_limit: 100)

    expect([layer.psi_micro(zero, nil), layer.psi_micro(full, nil), layer.psi_micro(over, nil)])
      .to eq([632_121, 0, 0])
  end

  it 'считает провайдера без лимита полностью обеспеченным бюджетом' do
    provider = build_provider(daily_amount_limit: nil)

    expect([layer.psi_micro(provider, nil), layer.deviation(provider, build_operation, nil)])
      .to eq([1_000_000, 0])
  end

  it 'читает psi из живого State::Providers после commit' do
    state = State::Providers.new(providers)
    payflow = by_name.fetch('payflow')
    operation = build_operation(operation_id: 'op_live_psi', amount: 50_000)

    before = layer.psi_micro(payflow, state)
    state.reserve(payflow, operation).commit(payflow, operation)
    after = layer.psi_micro(payflow, state)

    expect([before, after]).to eq([32_784, 16_529])
  end

  it 'ставит payflow последним, сохраняя исходный порядок остальных кандидатов' do
    vipay = by_name.fetch('vipay')
    payflow = by_name.fetch('payflow')
    quickpay = by_name.fetch('quickpay')

    first = layer.adjust([vipay, payflow, quickpay], build_operation, nil)
    second = layer.adjust([quickpay, payflow, vipay], build_operation, nil)

    expect(first.map(&:name)).to eq(%w[vipay quickpay payflow])
    expect(second.map(&:name)).to eq(%w[quickpay vipay payflow])
  end

  # Числа объяснения — в одном масштабе: psi, порог и отставание от порога.
  # Сырые миллионные доли наружу не выходят: «отклонение 67216» рядом с
  # «psi 0.033» читается как взятое с потолка.
  it 'объясняет порог, psi и отставание в одних единицах' do
    ranked_before = [by_name.fetch('vipay'), by_name.fetch('payflow'), by_name.fetch('quickpay')]
    ranked_after = layer.adjust(ranked_before, build_operation, nil)

    expect(layer.explain(ranked_before, ranked_after, build_operation, nil))
      .to include('0.033', 'ниже порога на 0.062', 'вмешиваемся с 90%')
    expect(layer.explain(ranked_before, ranked_after, build_operation, nil))
      .not_to include('62379')
  end

  it 'отклоняет нецелевой порог за пределами целого диапазона' do
    expect { described_class.new(activates_at_spent_pct: 101) }
      .to raise_error(ArgumentError, /activates_at_spent_pct.*101/)
  end

  it 'не использует Float, to_f или Math' do
    path = File.expand_path('../../../lib/routing/layers/budget_headroom.rb', __dir__)

    expect(File.read(path)).not_to match(/\.to_f\b|Float\(|Math\./)
  end
end
