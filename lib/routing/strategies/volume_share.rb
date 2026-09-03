# frozen_string_literal: true

require_relative '../strategies'

module Routing
  module Strategies
    class VolumeShare < Base
      def rank(candidates, _operation, state)
        candidates.sort { |left, right| compare(left, right, state) }
      end

      def name = 'volume_share'

      def explain(ranked, _operation, state)
        winner = ranked.first
        winner_text = "#{winner.name} дефицит #{deficit(winner, state)}"
        return "volume_share: #{winner_text}, других допустимых нет" if ranked.one?

        other = ranked[1]
        "volume_share: #{winner_text} против #{other.name} #{deficit(other, state)} " \
          "(веса #{weight_bp(winner)}/#{weight_bp(other)} bp)"
      end

      private

      def compare(left, right, state)
        left_deficit = deficit(left, state)
        right_deficit = deficit(right, state)
        return -1 if left_deficit > right_deficit
        return 1 if left_deficit < right_deficit
        return -1 if weight_bp(left) > weight_bp(right)
        return 1 if weight_bp(left) < weight_bp(right)

        left.name <=> right.name
      end

      def deficit(provider, state)
        (weight_bp(provider) * state.total_volume_units) - (10_000 * state.volume_units(provider))
      end

      def weight_bp(provider)
        (provider.volume_share_pct || provider.traffic_percentage).to_i * 100
      end
    end

    register('volume_share', VolumeShare)
  end
end
