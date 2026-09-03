# frozen_string_literal: true

require 'routing/constraints/daily_limit'
require 'routing/reasons'
require_relative '../../support/provider_factory'

RSpec.describe Routing::Constraints::DailyLimit do
  include ProviderFactory

  let(:payflow) do
    build_provider(payment_system: 'payflow', daily_approved_amount: 2_900_000,
                   daily_amount_limit: 3_000_000)
  end

  let(:payflow_violation) do
    {
      reason: 'daily_limit_exceeded',
      details: 'daily_approved_amount 2900000 + 150000 = 3050000 > daily_amount_limit 3000000'
    }
  end

  it 'пропускает сумму, которая ровно добивает до дневного лимита' do
    provider = build_provider(daily_approved_amount: 2_900_000, daily_amount_limit: 3_000_000)
    operation = build_operation(amount: 100_000)

    expect(described_class.violation(provider, operation, nil)).to be_nil
  end

  it 'отсеивает сумму на рубль выше дневного лимита' do
    provider = build_provider(daily_approved_amount: 2_900_000, daily_amount_limit: 3_000_000)
    operation = build_operation(amount: 100_001)

    expect(described_class.violation(provider, operation, nil).reason).to eq('daily_limit_exceeded')
  end

  it 'пропускает сумму без дневного лимита' do
    provider = build_provider(daily_amount_limit: nil)
    operation = build_operation(amount: 1_000_000)

    expect(described_class.violation(provider, operation, nil)).to be_nil
  end

  it 'считает nil daily_approved_amount нулём' do
    provider = build_provider(daily_approved_amount: nil, daily_amount_limit: 100)
    operation = build_operation(amount: 101)

    expect(described_class.violation(provider, operation, nil).reason).to eq('daily_limit_exceeded')
  end

  it 'отсеивает payflow из public-снапшота с каноническим details' do
    result = described_class.violation(payflow, build_operation(amount: 150_000), nil)

    expect(result).to have_attributes(payflow_violation)
  end
end
