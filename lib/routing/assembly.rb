# frozen_string_literal: true

require_relative 'layers'
require_relative 'selector'
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
      def strategy(config:, override: nil, history: nil)
        name, source = strategy_name(config, override)
        # Проверка до build, а не rescue вокруг него: иначе KeyError изнутри
        # from_config подменился бы сообщением «неизвестная стратегия».
        raise KeyError, unknown_message(name, source) unless Strategies.known.include?(name.to_s)

        Strategies.build(name, config: config, history: history)
      end

      # Пока всегда []: реестр слоёв пуст. Непустой список — KeyError на первом
      # же имени, молчаливого игнорирования нет.
      def layers(config:)
        config.layers.map { |name| Layers.build(name, config: config) }
      end

      # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- три чётких режима источника стратегии.
      def selector(config:, override: nil, history: nil)
        return cli_selector(config, override, history) if override && !override.to_s.empty?

        selection = config.strategy_selection
        if selection.nil? || selection.empty?
          return Selector::Static.new(strategy(config: config, history: history))
        end

        default_name = selection.fetch('default', config.strategy)
        default = build_named_strategy(default_name, config, 'strategy_selection.default', history)
        rules = selection.fetch('rules', [])
        return Selector::Static.new(default) if rules.empty?

        built_rules = rules.each_with_index.map do |rule, index|
          Selector::Rules::Rule.from_config(rule, index: index + 1, config: config)
        end
        Selector::Rules.new(default: default, rules: built_rules)
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

      def cli_selector(config, override, history = nil)
        selected = strategy(config: config, override: override, history: history)
        details = "selector: отключён флагом --strategy (1 источник) -> #{selected.name}"
        Selector::Static.new(selected, details: details)
      end

      def build_named_strategy(name, config, source, history = nil)
        unless Strategies.known.include?(name.to_s)
          raise KeyError, "Неизвестная стратегия #{name.inspect} (источник: #{source}); " \
                          "допустимы: #{Strategies.known.join(', ')}"
        end

        Strategies.build(name, config: config, history: history)
      end
    end
  end
end
