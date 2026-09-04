# frozen_string_literal: true

require_relative '../strategies'

module Routing
  module Strategies
    class Priority < Base
      def rank(candidates, _operation, _state)
        candidates.sort { |left, right| compare(left, right) }
      end

      def name = 'priority'

      def explain(ranked, _operation, _state)
        winner = ranked.first
        winner_text = "#{winner.name} priority=#{winner.priority}"
        return "priority: #{winner_text}, других допустимых нет" if ranked.one?

        other = ranked[1]
        "priority: #{winner_text} против #{other.name} priority=#{other.priority}"
      end

      private

      def compare(left, right)
        return left.priority <=> right.priority if left.priority != right.priority

        left.name <=> right.name
      end
    end

    register('priority', Priority)
  end
end
