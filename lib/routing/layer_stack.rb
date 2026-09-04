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

    def explain(ranked_before, _ranked_after, operation, state)
      layers.each_with_index.map do |layer, index|
        before = sort_by_prefix(ranked_before, layers.take(index), operation, state)
        after = sort_by_prefix(ranked_before, layers.take(index + 1), operation, state)
        layer.explain(before, after, operation, state)
      end
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

    def sort_by_prefix(ranked, prefix, operation, state)
      ranked.each_with_index.sort_by do |provider, index|
        prefix.map { |layer| valid_deviation(layer, provider, operation, state) } + [index]
      end.map(&:first)
    end
  end
end
