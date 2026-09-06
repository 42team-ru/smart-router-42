# frozen_string_literal: true

require 'time'

module Api
  # Агрегаты, которых нет в /report: гистограмма исходов, длина каскада и
  # временные ряды по корзинам. /report отвечает на вопрос «куда ушёл трафик
  # и почему», консоли дополнительно нужен вопрос «как это менялось во
  # времени» — считать его из /report нечем, там нет ни одной отметки времени.
  #
  # Всё считается по той же выборке фильтров (since/until/merchant/gate/
  # provider), что и /report с /decisions, — иначе плитки и графики на одном
  # экране разошлись бы.
  module AnalyticsBuilder
    OUTCOMES = %w[approved rejected expired no_provider].freeze
    DEFAULT_BUCKETS = 12

    def self.overview(repo:, filter: {}, buckets: DEFAULT_BUCKETS)
      decisions = repo.analytics_decisions(filter)
      attempts = repo.analytics_attempts(filter)
      approved = decisions.select { |row| row['simulated_result'] == 'approved' }

      {
        'total' => decisions.size,
        'outcomes' => outcomes(decisions),
        'attempt_histogram' => attempt_histogram(attempts),
        'approved_count' => approved.size,
        'approved_amount' => approved.sum { |row| row['amount'].to_i },
        'avg_latency_sec' => avg_latency(approved),
        'timeline' => timeline(decisions, attempts, buckets)
      }
    end

    def self.outcomes(decisions)
      counts = OUTCOMES.to_h { |key| [key, 0] }
      decisions.each do |row|
        result = row['simulated_result']
        counts[result] = counts.fetch(result, 0) + 1
      end
      counts
    end

    # Сколько решений дошло до N-й попытки. Читается как воронка каскада:
    # первая строка — все решения, последняя — те, кому не хватило и трёх
    # звеньев.
    def self.attempt_histogram(attempts)
      by_decision = attempts.group_by { |row| row['decision_id'] }
      return [] if by_decision.empty?

      lengths = by_decision.values.map(&:size)
      (1..lengths.max).map do |attempt_no|
        { 'attempt_no' => attempt_no, 'count' => lengths.count { |len| len >= attempt_no } }
      end
    end

    def self.avg_latency(approved)
      values = approved.filter_map { |row| row['latency_sec'] }
      return nil if values.empty?

      (values.sum.to_f / values.size).round(1)
    end

    # Окно строится по фактическим данным, а не по «последним N часам»: иначе
    # на свежей базе весь график схлопывается в одну корзину у правого края.
    def self.timeline(decisions, attempts, buckets)
      count = [buckets.to_i, 2].max
      stamps = decisions.map { |row| row['created_at'].to_i }
      return empty_timeline(count) if stamps.empty?

      from = stamps.min
      to = stamps.max
      width = [((to - from) / count.to_f).ceil, 1].max
      index = ->(ts) { [((ts - from) / width), count - 1].min }

      slots = Array.new(count) do
        { totals: 0, final: Hash.new(0), approved: Hash.new(0), tried: Hash.new(0) }
      end
      decisions.each do |row|
        slot = slots[index.call(row['created_at'].to_i)]
        slot[:totals] += 1
        provider = row['selected_provider']
        next if provider.nil?

        slot[:final][provider] += 1
        slot[:approved][provider] += 1 if row['simulated_result'] == 'approved'
      end
      attempts.each do |row|
        slots[index.call(row['created_at'].to_i)][:tried][row['provider']] += 1
      end

      {
        'from' => Time.at(from).utc.iso8601,
        'to' => Time.at(to).utc.iso8601,
        'bucket_seconds' => width,
        'buckets' => slots.each_with_index.map { |slot, i| bucket(slot, from + (i * width)) }
      }
    end

    def self.bucket(slot, at)
      {
        'at' => Time.at(at).utc.iso8601,
        'total' => slot[:totals],
        'by_provider' => slot[:final],
        'approved_by_provider' => slot[:approved],
        'attempts_by_provider' => slot[:tried]
      }
    end

    # Пустая выборка — не ошибка (см. /report): отдаём корзины нужной длины
    # с нулями и без отметок времени, чтобы фронт рисовал пустой график, а не
    # разбирал особый случай.
    def self.empty_timeline(count)
      blank = {
        'at' => nil, 'total' => 0,
        'by_provider' => {}, 'approved_by_provider' => {}, 'attempts_by_provider' => {}
      }.freeze
      {
        'from' => nil, 'to' => nil, 'bucket_seconds' => nil,
        'buckets' => Array.new(count) { blank.dup }
      }
    end
  end
end
