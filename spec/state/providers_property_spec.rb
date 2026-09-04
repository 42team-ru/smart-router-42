# frozen_string_literal: true

# T-7. Property-based тесты инвариантов State::Providers.
#
# Инварианты из §15 ARCH:
#   * in_progress_count и in_progress_amount возвращаются к исходному
#     после commit или rollback (expired держит, тест явно не проверяет).
#
# Вместо сторонней prop-lib используется Random с фиксированным seed:
# диагностика при падении воспроизводима, а spec/ не ограничен запретом
# rand/shuffle в lib/routing и lib/execution.

require 'state/providers'

PROPERTY_SEED = 20_260_904
PROPERTY_ITER = 200

# rubocop:disable RSpec/DescribeClass -- тест проверяет инварианты, а не один класс
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength
RSpec.describe 'инварианты State::Providers' do
  def random_providers(rng)
    %w[alpha beta gamma].map do |name|
      build_provider(name,
                     in_progress_count: rng.rand(10),
                     in_progress_amount: rng.rand(10) * 10_000,
                     available_requisites: 5)
    end + [build_spacepayments]
  end

  def random_operation(rng, id)
    build_operation(id: "op_#{id}", amount: (rng.rand(9) + 1) * 5_000)
  end

  describe 'reserve → commit: in_progress возвращается к исходному' do
    it 'для 200 случайных пар (provider, operation)' do
      rng = Random.new(PROPERTY_SEED)

      PROPERTY_ITER.times do |i|
        providers = random_providers(rng)
        state     = State::Providers.new(providers)
        provider  = providers.sample(random: rng)
        op        = random_operation(rng, i)

        initial_count  = state.in_progress_count(provider.name)
        initial_amount = state.in_progress_amount(provider.name)

        state.reserve(provider, op).commit(provider, op)

        msg_c = "commit[#{i}]: in_progress_count не вернулся к #{initial_count}"
        msg_a = "commit[#{i}]: in_progress_amount не вернулся к #{initial_amount}"
        expect(state.in_progress_count(provider.name)).to(eq(initial_count), msg_c)
        expect(state.in_progress_amount(provider.name)).to(eq(initial_amount), msg_a)
      end
    end
  end

  describe 'reserve → rollback: in_progress возвращается к исходному' do
    it 'для 200 случайных пар (provider, operation)' do
      rng = Random.new(PROPERTY_SEED + 1)

      PROPERTY_ITER.times do |i|
        providers = random_providers(rng)
        state     = State::Providers.new(providers)
        provider  = providers.sample(random: rng)
        op        = random_operation(rng, i)

        initial_count  = state.in_progress_count(provider.name)
        initial_amount = state.in_progress_amount(provider.name)

        state.reserve(provider, op).rollback(provider, op)

        msg_c = "rollback[#{i}]: in_progress_count не вернулся к #{initial_count}"
        msg_a = "rollback[#{i}]: in_progress_amount не вернулся к #{initial_amount}"
        expect(state.in_progress_count(provider.name)).to(eq(initial_count), msg_c)
        expect(state.in_progress_amount(provider.name)).to(eq(initial_amount), msg_a)
      end
    end
  end

  describe 'пакет N операций (commit/rollback): итоговый in_progress == исходный' do
    it 'для 100 случайных пакетов по 1..10 операций' do
      rng = Random.new(PROPERTY_SEED + 2)

      100.times do |batch|
        providers = random_providers(rng)
        state     = State::Providers.new(providers)
        external  = providers.reject { |p| p.name == 'spacepayments' }
        initial   = external.to_h do |p|
          [p.name, { count: state.in_progress_count(p.name),
                     amount: state.in_progress_amount(p.name) }]
        end

        (rng.rand(10) + 1).times do |i|
          provider = external.sample(random: rng)
          op       = random_operation(rng, "b#{batch}_#{i}")
          outcome  = rng.rand(2).zero? ? :commit : :rollback
          state.reserve(provider, op).public_send(outcome, provider, op)
        end

        external.each do |p|
          msg_c = "пакет #{batch}: #{p.name} in_progress_count не вернулся"
          msg_a = "пакет #{batch}: #{p.name} in_progress_amount не вернулся"
          expect(state.in_progress_count(p.name)).to(eq(initial[p.name][:count]), msg_c)
          expect(state.in_progress_amount(p.name)).to(eq(initial[p.name][:amount]), msg_a)
        end
      end
    end
  end

  describe 'daily_approved_amount не меняется при rollback' do
    it 'для 200 случайных операций' do
      rng = Random.new(PROPERTY_SEED + 3)

      PROPERTY_ITER.times do |i|
        providers        = random_providers(rng)
        state            = State::Providers.new(providers)
        provider         = providers.sample(random: rng)
        op               = random_operation(rng, i)
        initial_approved = state.daily_approved_amount(provider.name)

        state.reserve(provider, op).rollback(provider, op)

        msg = "rollback[#{i}]: daily_approved_amount изменился"
        expect(state.daily_approved_amount(provider.name)).to(eq(initial_approved), msg)
      end
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/ExampleLength
