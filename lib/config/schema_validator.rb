# frozen_string_literal: true

require_relative 'errors'
require_relative 'schema_rules'

module Config
  # CFG-1: структурная валидация распарсенного YAML конфига (ключи, типы).
  # Не проверяет, что имена стратегий/слоёв существуют как зарегистрированные
  # классы — это уже умеет Routing::Strategies.build, а реестра слоёв пока нет.
  module SchemaValidator
    # Новый top-level ключ конфига (например `selector` в Ф4, docs/TASKS.md X-3) —
    # добавить сюда одной строкой. Без этого валидатор отвергнет его как опечатку.
    KNOWN_TOP_LEVEL_KEYS = %w[
      strategy layers goals strategy_selection outcomes
      amount_ranges obligations rate_limits fallback_provider
    ].freeze

    def self.validate!(raw)
      validate_root!(raw)
      validate_known_keys!(raw)
      validate_required!(raw)
      validate_types!(raw)
    end

    def self.validate_root!(raw)
      return if raw.is_a?(Hash)

      raise SchemaError, "Корень конфига должен быть отображением, получено: #{raw.class}"
    end

    def self.validate_known_keys!(raw)
      unknown = raw.keys.map(&:to_s) - KNOWN_TOP_LEVEL_KEYS
      return if unknown.empty?

      raise SchemaError, "Неизвестный ключ конфига: #{unknown.join(', ')}; " \
                         "допустимые: #{KNOWN_TOP_LEVEL_KEYS.join(', ')}"
    end

    def self.validate_required!(raw)
      require_string!(raw, 'strategy')
      require_string!(raw, 'fallback_provider')
    end

    def self.require_string!(raw, key)
      value = raw[key]
      return if value.is_a?(String) && !value.empty?

      raise SchemaError, "Ключ `#{key}` обязателен и должен быть непустой строкой"
    end

    def self.validate_types!(raw)
      SchemaRules.validate_layers!(raw['layers'])
      SchemaRules.validate_amount_ranges!(raw['amount_ranges'])
      SchemaRules.validate_obligations!(raw['obligations'])
      SchemaRules.validate_rate_limits!(raw['rate_limits'])
      validate_hash!(raw['goals'], 'goals')
      validate_hash!(raw['strategy_selection'], 'strategy_selection')
      validate_hash!(raw['outcomes'], 'outcomes')
    end

    def self.validate_hash!(value, key)
      return if value.nil? || value.is_a?(Hash)

      raise SchemaError, "Ключ `#{key}` должен быть отображением, получено: #{value.class}"
    end

    private_class_method :validate_root!, :validate_known_keys!, :validate_required!,
                         :require_string!, :validate_types!, :validate_hash!
  end
end
