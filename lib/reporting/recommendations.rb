# frozen_string_literal: true

module Reporting
  # A-3/A-8: конкретный параметр и значение, а не наблюдение (ARCHITECTURE.md
  # §12) -- расхождение паспортной conversion_24h с историей и приближение
  # к дневному лимиту.
  module Recommendations
    CONVERSION_GAP_THRESHOLD = 0.05
    MAX_SLOTS_LEFT = 3
    TRAFFIC_STEP_DOWN = 15

    def self.build(pairs, providers, history)
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

    def self.conversion(provider, history)
      observed = history[provider.name]
      return nil if observed.nil? || provider.conversion_24h.nil?
      return nil if (provider.conversion_24h - observed).abs < CONVERSION_GAP_THRESHOLD

      "#{provider.name}: conversion_24h заявлена #{provider.conversion_24h}, " \
        "наблюдаемая #{observed} по истории — пересчитать по факту"
    end
    private_class_method :conversion

    def self.headroom(provider, avg_amount)
      return nil if provider.daily_amount_limit.nil? || provider.traffic_percentage.nil?
      return nil if avg_amount.zero?

      free = provider.daily_amount_limit - (provider.daily_approved_amount || 0)
      return nil if (free / avg_amount).floor > MAX_SLOTS_LEFT

      headroom_message(provider, free, avg_amount)
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
