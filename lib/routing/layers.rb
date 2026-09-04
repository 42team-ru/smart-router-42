# frozen_string_literal: true

require_relative 'layers/base'

module Routing
  # Реестр слоёв-модификаторов — близнец Routing::Strategies, но намеренно
  # пустой: слоёв в проекте ещё нет, они приезжают в Ф4 (X-1, X-2, X-3).
  #
  # Реестры раздельные: `layers: [conversion]` не должен подхватывать
  # Strategies::Conversion. У слоя и стратегии разные контракты (adjust против
  # rank), и молчаливая подмена выглядела бы как реализованный слой.
  module Layers
    # rubocop:disable-next Style/MutableConstant -- реестр расширяется регистрацией классов.
    REGISTRY = {}

    class << self
      def register(name, klass)
        key = name.to_s
        raise ArgumentError, "layer already registered: #{key}" if registry.key?(key)

        registry[key] = klass
        klass
      end

      def build(name)
        registry.fetch(name.to_s).new
      rescue KeyError
        raise KeyError, "unknown layer #{name.inspect}; #{hint}"
      end

      def known = registry.keys.sort

      private

      def hint
        return "известные слои: #{known.join(', ')}" unless known.empty?

        'слоёв пока нет: они приезжают в Ф4 (X-1, X-2)'
      end

      def registry
        REGISTRY
      end
    end
  end
end
