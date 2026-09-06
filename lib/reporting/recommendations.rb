# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Layout/LineLength

module Reporting
  # Конкретный параметр и значение, а не наблюдение -- расхождение паспортной
  # conversion_24h с историей и приближение к дневному лимиту.
  module Recommendations
    CONVERSION_GAP_THRESHOLD = 0.05

    # "Пересчитать по факту" звучит как установленный факт, а не догадка --
    # выдавать эту формулировку на маленькой выборке (payflow — 19 наблюдений
    # на reference/data/operations_history.csv) нечестно: 95%-й интервал
    # Уилсона для p≈0.5 на n=19 — это ±0.22, шире самого
    # CONVERSION_GAP_THRESHOLD. LARGE_SAMPLE_N — размер, на котором такой
    # интервал сжимается примерно до ширины самого порога (±0.05..0.06 при
    # p≈0.7-0.9) и дальнейшему сравнению с паспортом можно доверять; меньше --
    # верно только направление расхождения, не его величина.
    LARGE_SAMPLE_N = 200
    MAX_SLOTS_LEFT = 3
    TRAFFIC_STEP_DOWN = 15

    def self.build(pairs, providers, history)
      build_detailed(pairs, providers, history).map do |recommendation|
        recommendation.fetch('message')
      end
    end

    def self.build_detailed(pairs, providers, history)
      avg_amount = average_amount(pairs)

      providers.flat_map do |provider|
        [conversion(provider, history), headroom(provider, avg_amount)].compact
      end
    end

    def self.average_amount(pairs)
      return 0 if pairs.empty?

      pairs.sum { |operation, _| operation.amount }.to_f / pairs.size
    end
    private_class_method :average_amount

    # history -- Io::HistoryStats (см. lib/io/history_stats.rb): не просто
    # доля, а ещё и n (сколько операций видели), approved_count и k -- без
    # них рекомендация превращалась бы в "паспорт разошёлся с фактом" без
    # ответа на "а факту вообще можно верить на такой выборке".
    def self.conversion(provider, history)
      return nil unless history.known?(provider.name) && !provider.conversion_24h.nil?

      observed = history.approved_ratio(provider.name)
      return nil if (provider.conversion_24h - observed).abs < CONVERSION_GAP_THRESHOLD

      { 'code' => 'conversion_gap', 'provider' => provider.name, 'param' => 'conversion_24h',
        'current' => provider.conversion_24h, 'suggested' => observed,
        'evidence' => { 'observations' => history.observations(provider.name),
                        'approved' => history.approved_count(provider.name),
                        'gap_pp' => ((observed - provider.conversion_24h) * 100).round(1) },
        'severity' => history.observations(provider.name) >= LARGE_SAMPLE_N ? 'high' : 'medium',
        'message' => conversion_message(provider, history, observed) }
    end
    private_class_method :conversion

    def self.conversion_message(provider, history, observed)
      obs = history.observations(provider.name)
      estimate = estimate_text(history, observed)
      basis = "по истории #{history.approved_count(provider.name)}/#{obs} (#{estimate})"

      "#{provider.name}: conversion_24h заявлена #{provider.conversion_24h}, #{basis} — " \
        "#{verdict(obs)}"
    end
    private_class_method :conversion_message

    # Сглажена оценка или сырая -- видно явно, а не скрыто за одним числом:
    # сглаженная 0.551 при сырых 9/19 расходится с наивным approved/всего
    # (0.474) заметно, и это расхождение само по себе часть объяснения.
    def self.estimate_text(history, observed)
      return "наблюдаемая #{observed}" unless history.smoothed?

      "сглаженная оценка #{observed}, k=#{format('%.1f', history.k.to_f)}"
    end
    private_class_method :estimate_text

    # Вывод не сильнее, чем позволяют данные (см. LARGE_SAMPLE_N): на малой
    # выборке расхождение может быть шумом, а не фактом, и "пересчитать" было
    # бы преувеличением.
    def self.verdict(obs)
      return 'пересчитать по факту' if obs >= LARGE_SAMPLE_N

      'расхождение существенное, но выборка мала: проверить на большем периоде'
    end
    private_class_method :verdict

    def self.headroom(provider, avg_amount)
      return nil if provider.daily_amount_limit.nil? || provider.traffic_percentage.nil?
      return nil if avg_amount.zero?

      free = provider.daily_amount_limit - (provider.daily_approved_amount || 0)
      return nil if (free / avg_amount).floor > MAX_SLOTS_LEFT

      lowered = [provider.traffic_percentage - TRAFFIC_STEP_DOWN, 0].max
      { 'code' => 'limit_headroom', 'provider' => provider.name, 'param' => 'traffic_percentage',
        'current' => provider.traffic_percentage, 'suggested' => lowered,
        'evidence' => { 'free_amount' => free, 'average_amount' => avg_amount }, 'severity' => 'high',
        'message' => headroom_message(provider, free, avg_amount) }
    end
    private_class_method :headroom

    def self.headroom_message(provider, free, avg_amount)
      lowered = [provider.traffic_percentage - TRAFFIC_STEP_DOWN, 0].max
      amounts = "свободно #{format_amount(free)} ₽ при среднем чеке #{format_amount(avg_amount)} ₽"
      target = "traffic_percentage #{provider.traffic_percentage} → #{lowered}"

      "#{provider.name}: #{amounts} — снизить #{target} до сброса дневного лимита"
    end
    private_class_method :headroom_message

    def self.format_amount(amount)
      sign = amount.negative? ? '-' : ''
      "#{sign}#{amount.abs.round.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1 ').reverse}"
    end
    private_class_method :format_amount
  end
end
# rubocop:enable Metrics/AbcSize, Layout/LineLength
