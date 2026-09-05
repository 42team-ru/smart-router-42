# frozen_string_literal: true

require_relative '../strategies'

module Routing
  module Strategies
    # Ранжирует по договорным обязательствам об обороте.
    #
    # Гейт бывает выдан на условиях: «не меньше двух миллионов в сутки на этого
    # провайдера» или «не больше пяти на того». Это не технический лимит, а
    # коммерческая договорённость, и нарушать её дорого — вплоть до пересмотра
    # условий.
    #
    # Провайдеры делятся на три группы, и порядок между группами важнее любых
    # различий внутри:
    #
    #   0. не добрал минимум      — наверх, обязательство под угрозой
    #   1. в комфортной зоне      — середина
    #   2. подошёл к максимуму    — вниз, дальше грузить рискованно
    #
    # Внутри первой группы раньше идёт тот, кто дальше от своего минимума:
    # ему нужнее. Внутри третьей — у кого больше запаса до потолка. «Подошёл
    # к максимуму» — это 90% лимита, порог проверяется целочисленно
    # (оборот × 10 ≥ максимум × 9), без деления и float.
    #
    # Оборот считается как дневной снапшот провайдера плюс то, что добавил
    # текущий прогон. Стратегия видит только счётчики долей, не полное
    # состояние, и другого источника у неё нет — зато эта сумма честно отражает
    # «сколько у него набралось на сейчас».
    #
    # Отсутствующий минимум или максимум означает, что такого обязательства
    # нет, а не что оно равно нулю. Провайдер без обязательств всегда в средней
    # группе.
    #
    # Дальше по коду: config/routing.yml, ключ obligations — где задаются
    # пороги; Io::ProviderOverrides — как они накладываются на снапшот.
    class Obligations < Base
      MAX_THRESHOLD_NUMERATOR = 9
      MAX_THRESHOLD_DENOMINATOR = 10

      def rank(candidates, _operation, state)
        candidates.sort { |left, right| compare(left, right, state) }
      end

      def name = 'obligations'

      def explain(ranked, _operation, state)
        winner = ranked.first
        winner_text = "#{winner.name} оборот #{turnover(winner, state)}"
        return "obligations: #{winner_text}, других допустимых нет" if ranked.one?

        other = ranked[1]
        "obligations: #{winner_text} против #{other.name} оборот #{turnover(other, state)}"
      end

      private

      def compare(left, right, state)
        key(left, state) <=> key(right, state)
      end

      def key(provider, state)
        [tier(provider, state), secondary(provider, state), provider.name]
      end

      def tier(provider, state)
        return 0 if under_min?(provider, state)
        return 2 if near_max?(provider, state)

        1
      end

      def secondary(provider, state)
        min = provider.daily_turnover_min
        max = provider.daily_turnover_max
        current = turnover(provider, state)
        return current - min if under_min?(provider, state)
        return max - current if near_max?(provider, state)

        0
      end

      def under_min?(provider, state)
        min = provider.daily_turnover_min
        !min.nil? && turnover(provider, state) < min
      end

      def near_max?(provider, state)
        max = provider.daily_turnover_max
        return false if max.nil?

        turnover(provider, state) * MAX_THRESHOLD_DENOMINATOR >= max * MAX_THRESHOLD_NUMERATOR
      end

      def turnover(provider, state)
        provider.daily_approved_amount.to_i + state.volume_units(provider)
      end
    end

    register('obligations', Obligations)
  end
end
