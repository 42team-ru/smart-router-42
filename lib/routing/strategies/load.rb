# frozen_string_literal: true

require_relative '../strategies'

module Routing
  module Strategies
    # Ранжирует по текущей загрузке: свободнее — раньше.
    #
    # Сравнивается доля занятой ёмкости, а не абсолютное число заявок в работе:
    # три из пятнадцати и три из четырёх — разная загрузка. InProgress отвечает
    # только «есть ли ещё место» и пропускает провайдера, занятого на 99%; эта
    # стратегия смотрит на ту же цифру раньше, чтобы очередь не сходилась к
    # одному перегруженному каналу.
    #
    # Провайдер без лимита считается полностью свободным (0/1) и идёт первым.
    #
    # Доли сравниваются перекрёстным умножением, без деления и float.
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
