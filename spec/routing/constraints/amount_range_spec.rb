# frozen_string_literal: true

require 'routing/constraints/amount_range'
require 'routing/reasons'
require_relative '../../support/provider_factory'

RSpec.describe Routing::Constraints::AmountRange do
  include ProviderFactory

  it 'пропускает сумму, равную limit_amount_min' do
    provider = build_provider(limit_amount_min: 1_000)
    operation = build_operation(amount: 1_000)

    expect(described_class.violation(provider, operation, nil)).to be_nil
  end

  it 'пропускает сумму, равную limit_amount_max' do
    provider = build_provider(limit_amount_max: 100_000)
    operation = build_operation(amount: 100_000)

    expect(described_class.violation(provider, operation, nil)).to be_nil
  end

  it 'отсеивает сумму на рубль ниже минимума' do
    provider = build_provider(limit_amount_min: 1_000)
    operation = build_operation(amount: 999)

    expect(described_class.violation(provider, operation, nil).reason).to eq('amount_below_minimum')
  end

  it 'отсеивает op_107 ниже минимума с каноническим details' do
    provider = build_provider(limit_amount_min: 1_000)
    operation = build_operation(operation_id: 'op_107', amount: 800)

    expect(described_class.violation(provider, operation, nil)).to have_attributes(
      reason: 'amount_below_minimum', details: '800 < limit_amount_min 1000'
    )
  end

  it 'отсеивает op_103 выше максимума с каноническим details' do
    provider = build_provider(limit_amount_max: 100_000)
    operation = build_operation(operation_id: 'op_103', amount: 150_000)

    expect(described_class.violation(provider, operation, nil)).to have_attributes(
      reason: 'amount_exceeds_limit', details: '150000 > limit_amount_max 100000'
    )
  end

  it 'пропускает любую сумму, когда обе границы nil' do
    provider = build_provider(limit_amount_min: nil, limit_amount_max: nil)
    operation = build_operation(amount: 1_000_000)

    expect(described_class.violation(provider, operation, nil)).to be_nil
  end
end
