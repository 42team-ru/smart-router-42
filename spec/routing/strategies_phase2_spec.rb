# frozen_string_literal: true

require 'routing/share_ledger'
require 'routing/strategies/count_share'
require 'routing/strategies/volume_share'
require 'routing/achievable'
require_relative '../support/provider_factory'

# rubocop:disable-next RSpec/MultipleExpectations
RSpec.describe 'стратегии CountShare и VolumeShare' do
  include ProviderFactory

  let(:vipay) { build_provider(payment_system: 'vipay', traffic_percentage: 40) }
  let(:payflow) { build_provider(payment_system: 'payflow', traffic_percentage: 35) }
  let(:quickpay) { build_provider(payment_system: 'quickpay', traffic_percentage: 25) }
  let(:operation) { build_operation }
  let(:ledger) { Routing::ShareLedger.new }

  it 'регистрирует обе стратегии' do
    # include, а не eq: реестр общий на весь процесс, в нём уже все семь стратегий.
    expect(Routing::Strategies.known).to include('count_share', 'volume_share')
    expect(Routing::Strategies.build('count_share')).to be_a(Routing::Strategies::CountShare)
  end

  it 'CountShare начинает с порядка весов' do
    ranked = Routing::Strategies::CountShare.new.rank([quickpay, payflow, vipay], operation, ledger)

    expect(ranked).to eq([vipay, payflow, quickpay])
  end

  it 'CountShare учитывает закреплённую операцию' do
    ledger.reserve(vipay, operation)
    ranked = Routing::Strategies::CountShare.new.rank([vipay, payflow], operation, ledger)

    expect(ranked.first).to eq(payflow)
  end

  it 'VolumeShare учитывает объём, а не число операций' do
    ledger.reserve(vipay, operation)
    ranked = Routing::Strategies::VolumeShare.new.rank([vipay, payflow, quickpay], operation,
                                                       ledger)

    expect(ranked).to eq([payflow, quickpay, vipay])
  end

  it 'VolumeShare использует volume_share_pct при наличии' do
    boosted = build_provider(payment_system: 'quickpay', traffic_percentage: 25,
                             volume_share_pct: 50)
    ranked = Routing::Strategies::VolumeShare.new.rank([vipay, boosted], operation, ledger)

    expect(ranked.first).to eq(boosted)
  end

  it 'объяснение CountShare содержит числа' do
    expect(Routing::Strategies::CountShare.new.explain([vipay, payflow], operation,
                                                       ledger)).to match(/\d/)
  end

  it 'перенормирует допустимые веса до 10000 bp' do
    result = Routing::Achievable.renormalize([vipay, quickpay])

    expect(result).to eq('vipay' => 6154, 'quickpay' => 3846)
    expect(result.values.sum).to eq(10_000)
  end

  it 'распределяет десять мест как 4/3/3' do
    result = Routing::Achievable.apportion(
      { 'vipay' => 4000, 'payflow' => 3500, 'quickpay' => 2500 }, 10
    )

    expect(result).to eq('vipay' => 4, 'payflow' => 3, 'quickpay' => 3)
  end
end
