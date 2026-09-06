# frozen_string_literal: true

require_relative '../strategies'

module Routing
  module Strategies
    # Ранжирует по вероятности успешной выплаты: выше конверсия — раньше.
    #
    # Конверсия берётся не из снапшота: поле conversion_24h заявляет сам
    # провайдер, и на наших данных оно расходится с фактом почти вдвое (payflow
    # обещает 0.91, по истории 9 из 19). Цифра считается по
    # operations_history.csv со сглаживанием Дирихле (см. Io::HistoryLoader):
    # у payflow 19 наблюдений против 41 у vipay, сырая доля на такой выборке
    # ненадёжна.
    #
    # history — Io::HistoryStats, а не Hash{имя => Float}: ранжирование
    # сравнивает целые базисные пункты, без float, а explain показывает размер
    # выборки и применённое k.
    class Conversion < Base
      # history приходит уже загруженным из bin/route (ключ history_path).
      # Стратегия файл не открывает: диска касается только точка входа.
      def self.from_config(_config, history: nil) = new(history: history)

      # Без данных стратегия вырождается: все approved_bp нулевые, порядок
      # задаёт имя провайдера.
      def initialize(history: nil)
        super()
        @history = history
      end

      def rank(candidates, operation, _state)
        candidates.sort { |left, right| compare(left, right, operation.bank) }
      end

      def name = 'conversion'

      def explain(ranked, _operation, _state)
        winner = ranked.first
        winner_text = describe(winner, show_smoothing: true)
        return "conversion: #{winner_text}, других допустимых нет" if ranked.one?

        other = ranked[1]
        "conversion: #{winner_text} против #{describe(other, show_smoothing: false)}"
      end

      private

      def compare(left, right, bank)
        left_value = approved_bp(left, bank)
        right_value = approved_bp(right, bank)
        return -1 if left_value > right_value
        return 1 if left_value < right_value

        left.name <=> right.name
      end

      # Базисные пункты, не Float: сравнение целых, без округления.
      # Неизвестный провайдер получает дефолт HistoryStats (0).
      def approved_bp(provider, bank = nil)
        return 0 if @history.nil?

        bank ? @history.approved_bp_for(provider.name, bank) : @history.approved_bp(provider.name)
      end

      # ‰ только для explain, не для решения: Rational#round, без float.
      def permille(provider)
        Rational(approved_bp(provider), 10).round
      end

      def describe(provider, show_smoothing:)
        text = "#{provider.name} #{permille(provider)}‰"
        return text unless known?(provider)

        n = @history.observations(provider.name)
        note = smoothing_note if show_smoothing
        "#{text} (#{@history.approved_count(provider.name)}/#{n}#{note})"
      end

      def known?(provider) = !@history.nil? && @history.known?(provider.name)

      # k общий на всю историю, поэтому explain показывает его один раз — у
      # победителя.
      def smoothing_note
        return '' unless @history.smoothed? && @history.k.positive?

        ", сглажено k=#{format('%.1f', @history.k.to_f)}"
      end
    end

    register('conversion', Conversion)
  end
end
