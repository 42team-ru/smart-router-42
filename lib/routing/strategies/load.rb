# frozen_string_literal: true

require_relative '../strategies'

module Routing
  module Strategies
    # S-6: по возрастанию in_progress_count / in_progress_count_limit —
    # наименее загруженный провайдер идёт первым. nil/0 лимит = нет нагрузки,
    # тот же идиом, что и в Constraints::InProgress.
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
