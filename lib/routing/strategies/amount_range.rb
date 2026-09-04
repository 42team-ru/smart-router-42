# frozen_string_literal: true

require_relative '../strategies'
require_relative '../../config/loader'

module Routing
  module Strategies
    # S-4: полосы суммы из config/routing.yml (amount_ranges) ВЛИЯЮТ НА ПОРЯДОК,
    # а не только фильтруют — в отличие от Constraints::AmountRange (жёсткий
    # отсев по limit_amount_min/max провайдера). Это разные механизмы, оба
    # намеренно существуют (см. docs/ARCHITECTURE.md §8).
    #
    # Полосы приходят как хэши со строковыми ключами (сырой YAML через
    # Config::Loader): {"from"=>500, "to"=>50000, "prefer"=>"payflow"}.
    class AmountRange < Base
      CONFIG_PATH = File.expand_path('../../../config/routing.yml', __dir__)

      def initialize(ranges: self.class.default_ranges)
        super()
        @ranges = ranges
      end

      def self.default_ranges
        @default_ranges ||= Config::Loader.load(CONFIG_PATH).amount_ranges
      end

      def rank(candidates, operation, _state)
        preferred = preferred_name(operation.amount)
        candidates.sort { |left, right| compare(left, right, preferred) }
      end

      def name = 'amount_range'

      def explain(ranked, operation, _state)
        preferred = preferred_name(operation.amount) || 'никого'
        winner = ranked.first
        text = "amount_range: #{operation.amount}, полоса за #{preferred}, первый #{winner.name}"
        return text if ranked.one?

        "#{text}, второй #{ranked[1].name}"
      end

      private

      def compare(left, right, preferred)
        left_tier = tier(left, preferred)
        right_tier = tier(right, preferred)
        return left_tier <=> right_tier if left_tier != right_tier
        return left.priority <=> right.priority if left.priority != right.priority

        left.name <=> right.name
      end

      def tier(provider, preferred) = provider.name == preferred ? 0 : 1

      def preferred_name(amount)
        band = @ranges.find { |range| in_band?(range, amount) }
        band && band['prefer']
      end

      def in_band?(range, amount)
        from = range['from']
        to = range['to']
        (from.nil? || amount >= from) && (to.nil? || amount <= to)
      end
    end

    register('amount_range', AmountRange)
  end
end
