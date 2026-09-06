# frozen_string_literal: true

require 'routing/constraints/in_progress'
require 'state/providers'
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

  # rubocop:disable-next RSpec/ExampleLength -- проверяет причину и числа из живого State
  it 'берёт in_progress_count из живого состояния, а не из снимка' do
    provider = build_provider(in_progress_count: 0, in_progress_count_limit: 2)
    state = State::Providers.new([provider, build_provider(payment_system: 'spacepayments')])
    state.reserve(provider, build_operation(operation_id: 'op_first'))
    state.reserve(provider, build_operation(operation_id: 'op_second'))

    result = described_class.violation(provider, build_operation(operation_id: 'op_third'), state)

    expect(result).to have_attributes(
      reason: 'in_progress_limit_exceeded',
      details: 'in_progress_count 2 + 1 = 3 > in_progress_count_limit 2'
    )
  end

  it 'пропускает по живому состоянию, пока резервов меньше лимита' do
    provider = build_provider(in_progress_count: 0, in_progress_count_limit: 2)
    state = State::Providers.new([provider, build_provider(payment_system: 'spacepayments')])
    state.reserve(provider, build_operation(operation_id: 'op_first'))

    result = described_class.violation(provider, build_operation(operation_id: 'op_second'), state)

    expect(result).to be_nil
  end

  # rubocop:disable-next RSpec/ExampleLength -- проверяет причину и числа из живого State
  it 'берёт in_progress_amount из живого состояния, а не из снимка' do
    provider = build_provider(in_progress_count_limit: nil, in_progress_amount: 0,
                              in_progress_amount_limit: 100_000)
    state = State::Providers.new([provider, build_provider(payment_system: 'spacepayments')])
    state.reserve(provider, build_operation(operation_id: 'op_first', amount: 90_000))

    operation = build_operation(operation_id: 'op_second', amount: 20_000)
    result = described_class.violation(provider, operation, state)

    expect(result).to have_attributes(
      reason: 'in_progress_limit_exceeded',
      details: 'in_progress_amount 90000 + 20000 = 110000 > in_progress_amount_limit 100000'
    )
  end

  it 'при state = nil использует статический снимок, даже если живое состояние другое' do
    provider = build_provider(in_progress_count: 0, in_progress_count_limit: 1)
    state = State::Providers.new([provider, build_provider(payment_system: 'spacepayments')])
    state.reserve(provider, build_operation(operation_id: 'op_live'))

    result = described_class.violation(provider, build_operation(operation_id: 'op_static'), nil)

    expect(result).to be_nil
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
