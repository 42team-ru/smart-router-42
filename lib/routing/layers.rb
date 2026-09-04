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

      def build(name, config: nil)
        klass = registry.fetch(name.to_s)
        return klass.from_config(config) if config && klass.respond_to?(:from_config)

        klass.new
      rescue KeyError
        raise KeyError, "unknown layer #{name.inspect}; #{hint}"
      end

      def known = registry.keys.sort

      # Каталог слоёв загружается целиком, как каталог стратегий. Порядок файлов
      # наблюдаем через known и тексты ошибок, поэтому сортировка обязательна.
      def load_all!
        # rubocop:disable-next Lint/RedundantDirGlobSort -- порядок часть контракта.
        Dir[File.expand_path('layers/*.rb', __dir__)].sort.each { |path| require path }
        known
      end

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
