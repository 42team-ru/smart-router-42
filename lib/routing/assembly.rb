# frozen_string_literal: true

require_relative 'layers'
require_relative 'strategies'

module Routing
  # CFG-2: единственное место, где «конфиг плюс аргументы CLI» превращаются в
  # объекты пайплайна. Живёт в lib/, а не в bin/route, чтобы проверяться
  # юнит-спеком без запуска процесса.
  #
  # Диска не касается: конфиг приезжает готовым Config::RoutingConfig, читает
  # файл только bin/route. Конфиг не мутируется.
  module Assembly
    CLI_SOURCE = '--strategy'
    CONFIG_SOURCE = 'конфиг (ключ strategy, по умолчанию config/routing.yml)'

    class << self
      # override — значение --strategy или nil, если флаг не передавали.
      # Приоритет: CLI сильнее YAML, кода-дефолта стратегии не существует.
      def strategy(config:, override: nil)
        name, source = strategy_name(config, override)
        # Проверка до build, а не rescue вокруг него: иначе KeyError изнутри
        # from_config подменился бы сообщением «неизвестная стратегия».
        raise KeyError, unknown_message(name, source) unless Strategies.known.include?(name.to_s)

        Strategies.build(name, config: config)
      end

      # Пока всегда []: реестр слоёв пуст. Непустой список — KeyError на первом
      # же имени, молчаливого игнорирования нет.
      def layers(config:)
        config.layers.map { |name| Layers.build(name) }
      end

      private

      def unknown_message(name, source)
        "Неизвестная стратегия #{name.inspect} (источник: #{source}); " \
          "допустимы: #{Strategies.known.join(', ')}"
      end

      def strategy_name(config, override)
        return [override, CLI_SOURCE] if override && !override.to_s.empty?

        [config.strategy, CONFIG_SOURCE]
      end
    end
  end
end
