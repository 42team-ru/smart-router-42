# frozen_string_literal: true

require 'io/providers_loader'
require 'io/queue_loader'
require 'routing/achievable'
require 'routing/constraints'

# rubocop:disable-next RSpec/MultipleExpectations
RSpec.describe Routing::Achievable do
  let(:providers) { Io::ProvidersLoader.load(reference_path('providers.json')) }
  let(:operations) { Io::QueueLoader.load(reference_path('operations_queue_10.json')).operations }
  let(:eligibility) do
    operations.to_h do |operation|
      names = providers.reject { |provider| provider.name == 'spacepayments' }
                       .select { |provider| Routing::Constraints.eligible?(provider, operation) }
                       .map(&:name)
      [operation.operation_id, names]
    end
  end

  it 'считает осуществимую публичную долю 40/30/30' do
    result = described_class.for_queue(operations: operations, providers: providers,
                                       eligibility: eligibility)

    expect(result.transform_values { |value| value.fetch(:achievable_bp) }).to eq(
      'vipay' => 4000, 'payflow' => 3000, 'quickpay' => 3000
    )
  end

  it 'учитывает форсированные операции как нижнюю границу' do
    result = described_class.for_queue(operations: operations, providers: providers,
                                       eligibility: eligibility)

    expect(result.fetch('quickpay').fetch(:achievable_seats)).to be >= 3
    expect(result.fetch('payflow').fetch(:achievable_seats)).to be >= 1
  end

  it 'ограничивает payflow дневным headroom и помечает оба вида границ' do
    result = described_class.for_queue(operations: operations, providers: providers,
                                       eligibility: eligibility)

    expect(result.fetch('payflow')).to include(achievable_seats: 3, bound: :money)
    expect(result.fetch('quickpay')).to include(bound: :only_option)
  end

  it 'не зависит от nil-лимита fallback-провайдера' do
    result = described_class.for_queue(operations: operations, providers: providers,
                                       eligibility: eligibility)

    expect(result).not_to have_key('spacepayments')
  end

  it 'возвращает пустой результат для пустой очереди' do
    expect(described_class.for_queue(operations: [], providers: providers,
                                     eligibility: {})).to eq({})
  end

  it 'делит нулевые веса и нулевое число мест целочисленно' do
    weights = { 'a' => 0, 'b' => 0, 'c' => 0 }

    expect(described_class.apportion(weights, 3)).to eq('a' => 1, 'b' => 1, 'c' => 1)
    expect(described_class.apportion(weights, 0)).to eq('a' => 0, 'b' => 0, 'c' => 0)
  end
end
