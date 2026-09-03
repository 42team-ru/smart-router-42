# frozen_string_literal: true

require 'routing/constraints/in_progress'
require_relative '../../support/provider_factory'

RSpec.describe Routing::Constraints::InProgress do
  include ProviderFactory

  it 'пропускает последний влезающий слот по количеству' do
    provider = build_provider(in_progress_count: 9, in_progress_count_limit: 10)

    expect(described_class.violation(provider, build_operation, nil)).to be_nil
  end

  it 'отсеивает следующий слот по количеству с каноническим details' do
    provider = build_provider(in_progress_count: 10, in_progress_count_limit: 10)

    expect_count_limit_violation(described_class.violation(provider, build_operation, nil))
  end

  it 'пропускает сумму, которая ровно добивает лимит' do
    provider = build_provider(in_progress_amount: 900_000, in_progress_amount_limit: 1_000_000)
    operation = build_operation(amount: 100_000)

    expect(described_class.violation(provider, operation, nil)).to be_nil
  end

  it 'отсеивает сумму на рубль выше лимита' do
    provider = build_provider(in_progress_amount: 900_000, in_progress_amount_limit: 1_000_000)
    result = described_class.violation(provider, build_operation(amount: 100_001), nil)

    expect_amount_limit_violation(result)
  end

  it 'пропускает провайдера без обоих лимитов' do
    provider = build_provider(in_progress_count_limit: nil, in_progress_amount_limit: nil)

    expect(described_class.violation(provider, build_operation, nil)).to be_nil
  end

  it 'считает nil счётчики нулём' do
    provider = build_provider(in_progress_count: nil, in_progress_count_limit: 0)

    expect(described_class.violation(provider, build_operation, nil).reason)
      .to eq('in_progress_limit_exceeded')
  end

  it 'возвращает причину количества раньше причины суммы' do
    provider = both_limits_exceeded_provider

    expect(described_class.violation(provider, build_operation, nil).details)
      .to start_with('in_progress_count')
  end

  def expect_count_limit_violation(result)
    expect(result).to have_attributes(
      reason: 'in_progress_limit_exceeded',
      details: 'in_progress_count 10 + 1 = 11 > in_progress_count_limit 10'
    )
  end

  def expect_amount_limit_violation(result)
    expect(result).to have_attributes(
      reason: 'in_progress_limit_exceeded',
      details: 'in_progress_amount 900000 + 100001 = 1000001 > in_progress_amount_limit 1000000'
    )
  end

  def both_limits_exceeded_provider
    build_provider(in_progress_count: 10, in_progress_count_limit: 10,
                   in_progress_amount: 1_000_000, in_progress_amount_limit: 1_000_000)
  end
end
