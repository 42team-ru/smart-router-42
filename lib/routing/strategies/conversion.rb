# frozen_string_literal: true

require_relative '../strategies'

module Routing
  module Strategies
    # Ранжирует по вероятности успешной выплаты: выше конверсия — раньше.
    #
    # Смысл прямой: если провайдер доводит до успеха девять заявок из десяти,
    # а другой — семь, при прочих равных заявку стоит отдать первому. Меньше
    # отказов, короче каскад, быстрее деньги у получателя.
    #
    # Главное решение здесь — ОТКУДА берётся конверсия. Не из снапшота: поле
    # conversion_24h заявляет сам провайдер, и на наших данных оно расходится
    # с реальностью почти вдвое (payflow обещает 0.91, история — меньше).
    # Цифра считается по operations_history.csv, сглаженной методом Дирихле
    # (см. Io::HistoryLoader) — у payflow всего 19 наблюдений против 41 у
    # vipay, и сырое отношение approved/всего на такой выборке "уверенное на
    # вид, но статистически шаткое" число.
    #
    # history — Io::HistoryStats (см. lib/io/history_stats.rb), а не голый
    # Hash{имя => Float}: ранжирование сравнивает целые базисные пункты
    # (approved_bp), без перехода во float, а explain показывает размер
    # выборки и применённое k — иначе расхождение payflow с паспортом выглядит
    # как ошибка, а не как эффект маленькой выборки.
    class Conversion < Base
      # history — уже загруженные bin/route по пути из конфига (ключ
      # history_path). Стратегия файл не открывает: диска касается только
      # точка входа, иначе путь к данным оказался бы зашит в двух местах и
      # разъехался бы при первой же смене расположения файла.
      def self.from_config(_config, history: nil) = new(history: history)

      # Без данных стратегия честно вырождается: все approved_bp нулевые,
      # порядок задаёт имя провайдера. Молчаливое чтение файла «на всякий
      # случай» здесь хуже — оно скрыло бы, что данные не доехали.
      def initialize(history: nil)
        super()
        @history = history
      end

      def rank(candidates, _operation, _state)
        candidates.sort { |left, right| compare(left, right) }
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

      def compare(left, right)
        left_value = approved_bp(left)
        right_value = approved_bp(right)
        return -1 if left_value > right_value
        return 1 if left_value < right_value

        left.name <=> right.name
      end

      # Базисные пункты, не Float: сравнение целых чисел, без перекрёстного
      # умножения и без округления. @history.nil? -- честное вырождение без
      # чтения файла (см. комментарий у #initialize); неизвестный провайдер --
      # дефолт самого HistoryStats (0, см. Io::HistoryStats::DEFAULT_ENTRY).
      def approved_bp(provider)
        return 0 if @history.nil?

        @history.approved_bp(provider.name)
      end

      # ‰ только для explain (текст в attempts, не решение) -- Rational#round,
      # без float.
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

      # k — общий на всю историю, а не на провайдера: повторять его у каждого
      # кандидата было бы шумом, поэтому explain показывает его один раз, у
      # победителя (см. .explain выше).
      def smoothing_note
        return '' unless @history.smoothed? && @history.k.positive?

        ", сглажено k=#{format('%.1f', @history.k.to_f)}"
      end
    end

    register('conversion', Conversion)
  end
end
