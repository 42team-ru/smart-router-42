# frozen_string_literal: true

require_relative '../strategies'

module Routing
  module Strategies
    # Ранжирует по текущей загрузке: свободнее — раньше.
    #
    # Сравнивается не абсолютное число заявок в работе, а доля занятой ёмкости:
    # три заявки из пятнадцати — это свободный провайдер, три из четырёх —
    # почти забитый. Первым идёт тот, у кого доля меньше.
    #
    # Смысл в том, чтобы размазывать нагрузку до того, как упрёмся в потолок.
    # Проверка допуска InProgress отвечает только на вопрос «есть ли ещё место»,
    # и по ней провайдер годен, даже если занят на 99%. Эта стратегия смотрит на
    # ту же цифру раньше — чтобы очередь не сходилась к одному перегруженному
    # каналу и не начинала отваливаться по лимиту.
    #
    # Провайдер без лимита считается полностью свободным (доля 0/1) и потому
    # идёт первым — ограничения нет, занимать нечего.
    #
    # Доли сравниваются перекрёстным умножением, без деления: сравнение дробей
    # через float в решающем пути запрещено.
    class Load < Base
      def rank(candidates, _operation, _state)
        candidates.sort { |left, right| compare(left, right) }
      end

      def name = 'load'

      def explain(ranked, _operation, _state)
        winner = ranked.first
        numerator, denominator = ratio_parts(winner)
        winner_text = "#{winner.name} #{numerator}/#{denominator}"
        return "load: #{winner_text}, других допустимых нет" if ranked.one?

        other = ranked[1]
        other_numerator, other_denominator = ratio_parts(other)
        "load: #{winner_text} против #{other.name} #{other_numerator}/#{other_denominator}"
      end

      private

      def compare(left, right)
        left_numerator, left_denominator = ratio_parts(left)
        right_numerator, right_denominator = ratio_parts(right)
        left_value = left_numerator * right_denominator
        right_value = right_numerator * left_denominator
        return -1 if left_value < right_value
        return 1 if left_value > right_value

        left.name <=> right.name
      end

      def ratio_parts(provider)
        limit = provider.in_progress_count_limit
        return [0, 1] if limit.nil? || limit <= 0

        [provider.in_progress_count || 0, limit]
      end
    end

    register('load', Load)
  end
end
