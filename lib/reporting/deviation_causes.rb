# frozen_string_literal: true

require_relative '../offline/objective'

module Reporting
  # A-7: числовая причина каждого отклонения факта от паспортной цели.
  #
  # Отклонение раскладывается на структурную часть (bound из
  # Routing::Achievable.for_queue — допуск/дневной лимит) и остаток, который
  # формально объяснить нечем (:none). :only_option и :money — разные и не
  # взаимозаменяемые причины: провайдер, вынужденно перегруженный отсутствием
  # альтернатив, превышает цель; провайдер, урезанный дневным лимитом, её
  # недобирает. Перепутать их местами значит объяснить отклонение задом
  # наперёд — поэтому причина выбирается по bound, а не по знаку отклонения.
  #
  # Порог >= 5.0, а не > 5.0: на эталонной очереди максимальное отклонение
  # равно ровно 5.0 (quickpay +5.0 / payflow −5.0 — тот самый пример приёмки
  # из docs/TASKS.md и spec/fixtures/contracts/report.json). При строгом ">"
  # deviation_causes оставался бы пустым на данных, на которых демонстрируется
  # система.
  module DeviationCauses
    THRESHOLD_PP = 5.0

    def self.build(pairs, providers, achievable, eligibility)
      metrics = Offline::Objective.from_pairs(pairs, providers: providers)
      deviations = Offline::Objective.deviations_pp(counts: metrics.counts, providers: providers,
                                                    total: metrics.total)

      achievable.filter_map do |name, entry|
        deviation = deviations.fetch(name)
        next if deviation.abs < THRESHOLD_PP

        describe(name, deviation, entry, eligibility, pairs)
      end
    end

    def self.describe(name, deviation, entry, eligibility, pairs)
      case entry.fetch(:bound)
      when :only_option then forced_cause(name, deviation, eligibility, pairs)
      when :money then money_cause(name, deviation, entry, eligibility)
      else unexplained_cause(name, deviation)
      end
    end
    private_class_method :describe

    # Только singleton-допуск НЕ объясняет отклонение сам по себе — операция,
    # у которой этот провайдер был единственным вариантом, но которая в итоге
    # ушла не ему (хард-отказ, каскад), к превышению цели не привела. Поэтому
    # список — пересечение "единственный вариант" и "реально выбран".
    def self.forced_cause(name, deviation, eligibility, pairs)
      ops = forced_ops(name, eligibility, pairs)
      return unexplained_cause(name, deviation) if ops.empty?

      "#{name} #{format_pp(deviation)} п.п. к цели: #{ops.join(', ')} не имели " \
        'альтернатив по сумме и банку'
    end
    private_class_method :forced_cause

    def self.forced_ops(name, eligibility, pairs)
      singleton_ids = eligibility.select { |_id, names| Array(names) == [name] }.keys

      pairs.filter_map do |operation, outcome|
        next unless singleton_ids.include?(operation.operation_id)
        next unless outcome.selected.name == name

        operation.operation_id
      end
    end
    private_class_method :forced_ops

    def self.money_cause(name, deviation, entry, eligibility)
      eligible_count = eligibility.values.count { |names| Array(names).include?(name) }
      seats = entry.fetch(:achievable_seats)
      shortfall = eligible_count - seats

      "#{name} #{format_pp(deviation)} п.п. к цели: дневной лимит пропустил #{seats} из " \
        "#{eligible_count} допустимых операций (не хватило места для #{shortfall})"
    end
    private_class_method :money_cause

    def self.unexplained_cause(name, deviation)
      "#{name} #{format_pp(deviation)} п.п. к цели: структурная причина не определена " \
        '(допуск и дневной лимит не ограничивают) — требуется разбор вручную'
    end
    private_class_method :unexplained_cause

    def self.format_pp(value)
      sign = value.negative? ? '-' : '+'
      magnitude = value.abs
      number = (magnitude % 1).zero? ? magnitude.to_i.to_s : format('%.1f', magnitude)
      "#{sign}#{number}"
    end
    private_class_method :format_pp
  end
end
