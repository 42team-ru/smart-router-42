# frozen_string_literal: true

require 'routing/layers/share_ceiling'
require 'routing/share_ledger'
require_relative '../../support/provider_factory'

# rubocop:disable-next RSpec/MultipleExpectations -- одна цель проверяется парой счётчиков.
RSpec.describe Routing::Layers::ShareCeiling do
  include ProviderFactory

  let(:quickpay) { build_provider(payment_system: 'quickpay', traffic_percentage: 25) }
  let(:vipay) { build_provider(payment_system: 'vipay', traffic_percentage: 40) }
  let(:operation) { build_operation }

  # rubocop:disable-next RSpec/ExampleLength -- проверяем оба кандидата на общей пустой истории.
  it 'даёт нулевое отклонение на пустой истории' do
    state = Routing::ShareLedger.new

    deviations = [quickpay, vipay].map do |provider|
      described_class.new.deviation(provider, operation, state)
    end

    expect(deviations)
      .to eq([0, 0])
  end

  it 'считает превышение quickpay и не штрафует vipay' do
    state = state_with_counts(quickpay => 4, vipay => 2)

    expect(described_class.new.deviation(quickpay, operation, state)).to eq(25_000)
    expect(described_class.new.deviation(vipay, operation, state)).to eq(0)
  end

  it 'учитывает tolerance_bp в общем знаменателе операции' do
    three_percent = state_with_counts(quickpay => 28, vipay => 72)
    seven_percent = state_with_counts(quickpay => 32, vipay => 68)
    layer = described_class.new(tolerance_bp: 500)

    expect(layer.deviation(quickpay, operation, three_percent)).to eq(0)
    expect(layer.deviation(quickpay, operation, seven_percent)).to eq(70_000)
  end

  it 'ставит перебравшего в хвост и сохраняет порядок остальных' do
    state = state_with_counts(quickpay => 4, vipay => 2)
    payflow = build_provider(payment_system: 'payflow', traffic_percentage: 35)

    expect(described_class.new.adjust([quickpay, vipay, payflow], operation, state).map(&:name))
      .to eq(%w[vipay payflow quickpay])
  end

  it 'не использует Float или to_f в расчёте доли' do
    path = File.expand_path('../../../lib/routing/layers/share_ceiling.rb', __dir__)

    expect(File.read(path)).not_to match(/\.to_f\b|Float\(/)
  end

  def state_with_counts(counts)
    state = Routing::ShareLedger.new
    counts.each do |provider, count|
      count.times do |index|
        reserved = build_operation(operation_id: "#{provider.name}_#{index}")
        state.reserve(provider, reserved).commit(provider, reserved)
      end
    end
    state
  end
end
