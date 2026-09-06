# frozen_string_literal: true

require_relative '../offline/objective'

module Reporting
  # Числовая причина каждого отклонения факта от паспортной цели.
  #
  # Отклонение раскладывается на структурную часть (bound из
  # Routing::Achievable.for_queue/for_volume — допуск/дневной лимит) и остаток, который
  # формально объяснить нечем (:none). :only_option и :money — разные и не
  # взаимозаменяемые причины: провайдер, вынужденно перегруженный отсутствием
  # альтернатив, превышает цель; провайдер, урезанный дневным лимитом, её
  # недобирает. Перепутать их местами значит объяснить отклонение задом
  # наперёд — поэтому причина выбирается по bound, а не по знаку отклонения.
  #
  # Порог >= 5.0, а не > 5.0: на эталонной очереди максимальное отклонение
  # равно ровно 5.0 (quickpay +5.0 / payflow −5.0 — см. spec/fixtures/contracts/report.json).
  # При строгом ">" deviation_causes оставался бы пустым на данных, на которых
  # демонстрируется система.
  #
  # По объёму причины формируются той же логикой (build_volume), только мерой
  # служат рубли, achievable берётся из Routing::Achievable.for_volume, а
  # сообщение помечено "по объёму", чтобы не перепутать со строкой по
  # количеству о том же провайдере. achievable_volume по умолчанию пуст --
  # старые вызовы (без пятого аргумента) получают только причины по количеству.
  # rubocop:disable-next Metrics/ModuleLength -- количество и объём формулируются параллельно, каждый в своём наборе методов.
  module DeviationCauses
    THRESHOLD_PP = 5.0

    def self.build(pairs, providers, achievable, eligibility, achievable_volume: {})
      build_count(pairs, providers, achievable, eligibility) +
        build_volume(pairs, providers, achievable_volume, eligibility)
    end

    def self.build_count(pairs, providers, achievable, eligibility)
      metrics = Offline::Objective.from_pairs(pairs, providers: providers)
      deviations = Offline::Objective.deviations_pp(counts: metrics.counts, providers: providers,
                                                    total: metrics.total)

      achievable.filter_map do |name, entry|
        deviation = deviations.fetch(name)
        next if deviation.abs < THRESHOLD_PP

        describe(name, deviation, entry, eligibility, pairs)
      end
    end
    private_class_method :build_count

    # Отклонение здесь -- тоже от ПАСПОРТНОЙ цели по объёму (volume_share_pct
    # с фоллбэком на traffic_percentage), а не от достижимой: achievable/bound
    # объясняют, ПОЧЕМУ факт разошёлся с обещанным, а не служат новой базой
    # отсчёта -- симметрично build_count, который меряет от traffic_percentage,
    # а не от achievable_bp.
    def self.build_volume(pairs, providers, achievable_volume, eligibility)
      return [] if achievable_volume.empty?

      by_name = providers.to_h { |provider| [provider.name, provider] }
      total = pairs.sum { |operation, _| operation.amount }

      achievable_volume.filter_map do |name, entry|
        part = volume_of(pairs, name)
        target_bp = volume_target_bp(by_name.fetch(name))
        deviation = volume_deviation_pp(part, target_bp, total)
        next if deviation.abs < THRESHOLD_PP

        describe_volume(name, deviation, entry, eligibility, pairs)
      end
    end
    private_class_method :build_volume

    def self.volume_of(pairs, name)
      pairs.sum { |operation, outcome| outcome.selected.name == name ? operation.amount : 0 }
    end
    private_class_method :volume_of

    def self.volume_target_bp(provider)
      (provider.volume_share_pct || provider.traffic_percentage).to_i *
        Offline::Objective::BASIS_POINTS_PER_PERCENT
    end
    private_class_method :volume_target_bp

    def self.volume_deviation_pp(part, target_bp, total)
      return 0.0 if total.zero?

      numerator = (part * Offline::Objective::SCALE) - (target_bp * total)
      Rational(numerator, total * Offline::Objective::BASIS_POINTS_PER_PERCENT).to_f.round(1)
    end
    private_class_method :volume_deviation_pp

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

    def self.describe_volume(name, deviation, entry, eligibility, pairs)
      case entry.fetch(:bound)
      when :only_option then forced_volume_cause(name, deviation, eligibility, pairs)
      when :money then money_volume_cause(name, deviation, entry, eligibility, pairs)
      else unexplained_volume_cause(name, deviation)
      end
    end
    private_class_method :describe_volume

    # Тот же инвариант, что у forced_cause: singleton-допуск объясняет
    # отклонение только для операций, реально ушедших этому провайдеру.
    def self.forced_volume_cause(name, deviation, eligibility, pairs)
      ops = forced_volume_ops(name, eligibility, pairs)
      return unexplained_volume_cause(name, deviation) if ops.empty?

      ids = ops.map(&:operation_id).join(', ')
      sum = ops.sum(&:amount)
      "#{name} #{format_pp(deviation)} п.п. по объёму: операции #{ids} на сумму " \
        "#{format_amount(sum)} ₽ не имели альтернатив по сумме и банку"
    end
    private_class_method :forced_volume_cause

    def self.forced_volume_ops(name, eligibility, pairs)
      singleton_ids = eligibility.select { |_id, names| Array(names) == [name] }.keys

      pairs.filter_map do |operation, outcome|
        next unless singleton_ids.include?(operation.operation_id)
        next unless outcome.selected.name == name

        operation
      end
    end
    private_class_method :forced_volume_ops

    def self.money_volume_cause(name, deviation, entry, eligibility, pairs)
      eligible_amount = pairs.sum do |operation, _|
        Array(eligibility[operation.operation_id]).include?(name) ? operation.amount : 0
      end
      achievable_amount = entry.fetch(:achievable_amount)
      shortfall = eligible_amount - achievable_amount

      "#{name} #{format_pp(deviation)} п.п. по объёму: дневной лимит пропустил " \
        "#{format_amount(achievable_amount)} ₽ из #{format_amount(eligible_amount)} ₽ " \
        "допустимых (не хватило #{format_amount(shortfall)} ₽)"
    end
    private_class_method :money_volume_cause

    def self.unexplained_volume_cause(name, deviation)
      "#{name} #{format_pp(deviation)} п.п. по объёму: структурная причина не определена " \
        '(допуск и дневной лимит не ограничивают) — требуется разбор вручную'
    end
    private_class_method :unexplained_volume_cause

    def self.format_amount(amount)
      sign = amount.negative? ? '-' : ''
      "#{sign}#{amount.abs.round.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1 ').reverse}"
    end
    private_class_method :format_amount

    def self.format_pp(value)
      sign = value.negative? ? '-' : '+'
      magnitude = value.abs
      number = (magnitude % 1).zero? ? magnitude.to_i.to_s : format('%.1f', magnitude)
      "#{sign}#{number}"
    end
    private_class_method :format_pp
  end
end
