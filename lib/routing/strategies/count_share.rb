# frozen_string_literal: true

require_relative '../strategies'

module Routing
  module Strategies
    class CountShare < Base
      def rank(candidates, _operation, state)
        candidates.sort { |left, right| compare(left, right, state) }
      end

      def name = 'count_share'

      def explain(ranked, _operation, state)
        winner = ranked.first
        numerator, denominator = quotient_parts(winner, state)
        winner_text = "#{winner.name} #{numerator}/#{denominator}=#{numerator / denominator}"
        return "count_share: #{winner_text}, других допустимых нет" if ranked.one?

        other = ranked[1]
        other_numerator, other_denominator = quotient_parts(other, state)
        "count_share: #{winner_text} против #{other.name} " \
          "#{other_numerator}/#{other_denominator}=#{other_numerator / other_denominator}"
      end

      private

      def compare(left, right, state)
        left_weight = weight_bp(left)
        right_weight = weight_bp(right)
        left_value = left_weight * divisor(right, state)
        right_value = right_weight * divisor(left, state)
        return -1 if left_value > right_value
        return 1 if left_value < right_value
        return -1 if left_weight > right_weight
        return 1 if left_weight < right_weight

        left.name <=> right.name
      end

      def quotient_parts(provider, state) = [weight_bp(provider), divisor(provider, state)]

      def divisor(provider, state) = (2 * state.count_units(provider)) + 1

      def weight_bp(provider) = provider.traffic_percentage.to_i * 100
    end

    register('count_share', CountShare)
  end
end
