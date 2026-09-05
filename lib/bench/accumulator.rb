# frozen_string_literal: true

require 'digest'

module Bench
  # Копит агрегаты по одной паре (Domain::Operation, Execution::Outcome) за
  # раз, O(1) на операцию, без накопления пар в памяти — это то, что делает
  # уровни l/xl/insane вообще возможными (ReportBuilder на 5 млн операций
  # держал бы весь pairs целиком).
  #
  # Поля пересекаются с Reporting::Distributions намеренно: spec/bench/
  # accumulator_spec.rb сверяет их на уровне smoke против настоящего
  # Reporting::ReportBuilder — единственная защита от того, что быстрый
  # агрегатор считает не то же самое, что боевой отчёт. achievable_pct/
  # target_pct/deviation_pp сюда не входят: они требуют Routing::Achievable
  # (O(operations · providers) и хеш на все operation_id), который на этих
  # масштабах намеренно отключён (см. план бенчмарка).
  class Accumulator
    attr_accessor :queue_errors
    attr_reader :total, :delivered

    # rubocop:disable-next Metrics/AbcSize -- инициализация независимых счётчиков одного прохода.
    def initialize(provider_names:)
      @counts = provider_names.to_h { |name| [name, 0] }
      @amounts = provider_names.to_h { |name| [name, 0] }
      @attempts = provider_names.to_h { |name| [name, 0] }
      @successful = provider_names.to_h { |name| [name, 0] }
      @skip_reasons = Hash.new(0)
      @fallback_first = @fallback_recovered = @fallback_exhausted = @spacepayments_used = 0
      @delivered = 0
      @total = 0
      @queue_errors = 0
      @digest = Digest::SHA256.new
    end

    # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength
    def add(operation, outcome)
      @total += 1
      name = outcome.selected.name
      @counts[name] += 1
      @amounts[name] += operation.amount
      @delivered += 1 unless outcome.result == :rejected

      real_attempts = 0
      outcome.attempts.each do |attempt|
        if attempt.decision == 'selected'
          real_attempts += 1
          attempt_name = provider_name(attempt.provider)
          @attempts[attempt_name] += 1
          @successful[attempt_name] += 1 if attempt.result == 'approved'
        else
          @skip_reasons[attempt.reason] += 1
        end
      end
      classify_fallback(outcome, real_attempts)
      @digest << "#{operation.operation_id}:#{name}:#{outcome.result}\n"
      self
    end

    def digest_hex = @digest.hexdigest

    def distribution
      @counts.to_h do |name, count|
        [name, { 'count' => count, 'share_pct' => percentage(count, @total) }]
      end
    end

    def volume_distribution
      total_amount = @amounts.values.sum
      @amounts.to_h do |name, amount|
        [name, { 'amount' => amount, 'share_pct' => percentage(amount, total_amount) }]
      end
    end

    def attempt_distribution
      @attempts.to_h do |name, attempts|
        successful = @successful.fetch(name)
        conversion = attempts.zero? ? nil : (successful.to_f / attempts).round(3)
        [name, { 'attempts' => attempts, 'successful' => successful,
                 'observed_conversion' => conversion }]
      end
    end

    def skip_reasons = @skip_reasons.dup

    def fallback
      {
        'first_attempt_success' => @fallback_first, 'recovered_by_fallback' => @fallback_recovered,
        'fallback_rate_pct' => fallback_rate_pct, 'spacepayments_used' => @spacepayments_used,
        'cascade_exhausted' => @fallback_exhausted
      }
    end

    private

    # Execution::Executor кладёт в Attempt#provider объект Domain::Provider
    # (или fallback-провайдера) — в JSON-контракте decisions.json его в строку
    # превращает bin/route (explain_first_attempt/rebuild_attempt); здесь
    # decisions.json не пишется, поэтому нормализуем сами.
    def provider_name(provider) = provider.respond_to?(:name) ? provider.name : provider

    # Дословно как Reporting::ReportBuilder.spacepayments_used/.fallback_stat
    # (any?, а не "последняя попытка") — совпадение поведения проверяет
    # spec/bench/accumulator_spec.rb на smoke.
    def classify_fallback(outcome, real_attempts)
      if outcome.attempts.any? do |attempt|
           attempt.decision == 'selected' && attempt.reason == 'fallback_no_eligible_provider'
         end
        @spacepayments_used += 1
      end
      return @fallback_exhausted += 1 unless outcome.result == :approved

      real_attempts > 1 ? @fallback_recovered += 1 : @fallback_first += 1
    end

    def fallback_rate_pct
      return 0.0 if @total.zero?

      (@fallback_recovered.to_f / @total * 100).round(1)
    end

    def percentage(part, total)
      return 0.0 if total.zero?

      (part.to_f / total * 100).round(1)
    end
  end
end
