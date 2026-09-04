# frozen_string_literal: true

module Routing
  # Лексикографическая композиция целей: первый слой имеет высший приоритет,
  # порядок базовой стратегии остаётся последним уровнем разрешения равенств.
  class LayerStack
    def initialize(layers)
      @layers = layers.freeze
    end

    def adjust(ranked, operation, state)
      return ranked if empty?

      ranked.each_with_index.sort_by do |provider, index|
        layers.map { |layer| valid_deviation(layer, provider, operation, state) } + [index]
      end.map(&:first)
    end

    def explain(ranked_before, ranked_after, operation, state)
      layers.map { |layer| layer.explain(ranked_before, ranked_after, operation, state) }
    end

    def empty? = layers.empty?

    private

    attr_reader :layers

    def valid_deviation(layer, provider, operation, state)
      value = layer.deviation(provider, operation, state)
      return value if value.is_a?(Integer) && value >= 0

      raise ArgumentError,
            "#{layer.name} deviation must be a non-negative Integer, got #{value.inspect}"
    end
  end
end
