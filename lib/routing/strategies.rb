# frozen_string_literal: true

require_relative 'strategies/base'

module Routing
  module Strategies
    # rubocop:disable-next Style/MutableConstant -- реестр расширяется регистрацией классов.
    REGISTRY = {}

    class << self
      def register(name, klass)
        key = name.to_s
        raise ArgumentError, "strategy already registered: #{key}" if registry.key?(key)

        registry[key] = klass
        klass
      end

      # config: объект Config::RoutingConfig или nil. Реестр про его внутренности
      # не знает: класс, которому нужны данные конфига, объявляет фабрику
      # `def self.from_config(config)`. Без конфига (и без фабрики) — klass.new,
      # от этого зависит spec/support/shared/strategy_contract.rb.
      def build(name, config: nil)
        klass = fetch!(name)
        return klass.from_config(config) if config && klass.respond_to?(:from_config)

        klass.new
      end

      def known = registry.keys.sort

      # CFG-3: новая стратегия — это только файл в каталоге плюс строка в
      # конфиге. Ни bin/route, ни реестр имён стратегий не знают.
      # .sort обязателен: порядок регистрации виден в known и в текстах ошибок,
      # а полагаться на неявную сортировку Dir.glob из Ruby 3.0 в инварианте
      # детерминизма нельзя — она деталь реализации, а не наш контракт.
      # base.rb грузится безопасно — он ничего не регистрирует.
      def load_all!
        # rubocop:disable-next Lint/RedundantDirGlobSort -- см. комментарий выше
        Dir[File.expand_path('strategies/*.rb', __dir__)].sort.each { |path| require path }
        known
      end

      private

      # rescue живёт здесь, а не вокруг build: иначе KeyError изнутри from_config
      # превратился бы в «unknown strategy» и спрятал настоящую ошибку.
      def fetch!(name)
        registry.fetch(name.to_s)
      rescue KeyError
        raise KeyError, "unknown strategy #{name.inspect}; known: #{known.join(', ')}"
      end

      def registry
        REGISTRY
      end
    end
  end
end
