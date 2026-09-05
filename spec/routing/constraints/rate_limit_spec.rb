# frozen_string_literal: true

require 'routing/constraints/rate_limit'
require 'routing/constraints'
require_relative '../../support/provider_factory'

RSpec.describe Routing::Constraints::RateLimit do
  include ProviderFactory

  def state_with_count(count)
    Object.new.tap do |state|
      state.define_singleton_method(:requests_in_minute) { |_provider_name, _minute_key| count }
    end
  end

  let(:rate_limit_violation) do
    {
      reason: 'rate_limit_exceeded',
      details: 'запросов за минуту 7 + 1 = 8 > requests_per_minute_limit 7'
    }
  end

  it 'пропускает провайдера без минутного лимита' do
    provider = build_provider(requests_per_minute_limit: nil)

    expect(described_class.violation(provider, build_operation, nil)).to be_nil
  end

  it 'пропускает провайдера, когда состояние отсутствует' do
    provider = build_provider(requests_per_minute_limit: 7)

    expect(described_class.violation(provider, build_operation, nil)).to be_nil
  end

  it 'пропускает провайдера, когда состояние не предоставляет счётчик' do
    provider = build_provider(requests_per_minute_limit: 7)

    expect(described_class.violation(provider, build_operation, Object.new)).to be_nil
  end

  it 'пропускает запрос, который ровно добивает до лимита' do
    provider = build_provider(requests_per_minute_limit: 7)

    expect(described_class.violation(provider, build_operation, state_with_count(6))).to be_nil
  end

  it 'отсеивает запрос выше лимита с канонической причиной' do
    provider = build_provider(requests_per_minute_limit: 7)
    result = described_class.violation(provider, build_operation, state_with_count(7))

    expect(result).to have_attributes(**rate_limit_violation)
  end

  it 'пропускает провайдера, когда счётчик не вернул значение' do
    provider = build_provider(requests_per_minute_limit: 7)

    expect(described_class.violation(provider, build_operation, state_with_count(nil))).to be_nil
  end

  it 'выводит ключ минуты из времени операции' do
    operation = build_operation(created_at: '2026-07-30T09:05:30+03:00')

    expect(described_class.minute_key(operation)).to eq('2026-07-30T09:05')
  end

  # RateLimit больше не в Routing::Constraints::REGISTRY -- этот тест защищает
  # Routing::Achievable
  # и ReportBuilder.eligibility_for, которые вызывают Constraints.eligible? без
  # состояния и не должны заметить появление requests_per_minute_limit в
  # снапшоте.
  # rubocop:disable RSpec/MultipleExpectations -- eligible?/check проверяются
  # одной парой утверждений, это один и тот же факт про один и тот же вызов.
  describe 'Routing::Constraints.eligible?/.check без состояния (защита Achievable/отчёта)' do
    it 'превышение лимита не отсеивает, когда state == nil, даже если лимит задан в снапшоте' do
      provider = build_provider(requests_per_minute_limit: 7)

      expect(Routing::Constraints.eligible?(provider, build_operation, nil)).to be(true)
      expect(Routing::Constraints.check(provider, build_operation, nil)).to be_nil
    end

    it 'eligible? без state даёт тот же ответ, как если бы RateLimit не было в REGISTRY' do
      provider = build_provider(requests_per_minute_limit: 7)

      expect(Routing::Constraints::REGISTRY).not_to include(described_class)
      expect(Routing::Constraints.eligible?(provider, build_operation)).to be(true)
    end
  end
  # rubocop:enable RSpec/MultipleExpectations
end
