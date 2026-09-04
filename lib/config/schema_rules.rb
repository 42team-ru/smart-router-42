# frozen_string_literal: true

require_relative 'errors'

module Config
  # CFG-1: валидация полей-коллекций конфига (layers, amount_ranges, obligations,
  # rate_limits). Вынесено из SchemaValidator отдельным модулем, чтобы оба файла
  # оставались небольшими и проверяемыми по отдельности.
  module SchemaRules
    OBLIGATION_KEYS = %w[daily_turnover_min daily_turnover_max].freeze

    def self.validate_layers!(layers)
      return if layers.nil?
      return if layers.is_a?(Array) && layers.all?(String)

      raise SchemaError, "Ключ `layers` должен быть списком строк, получено: #{layers.inspect}"
    end

    def self.validate_amount_ranges!(ranges)
      return if ranges.nil?

      raise SchemaError, 'Ключ `amount_ranges` должен быть списком' unless ranges.is_a?(Array)

      ranges.each_with_index { |range, index| validate_amount_range_entry!(range, index) }
    end

    def self.validate_amount_range_entry!(range, index)
      raise SchemaError, "amount_ranges[#{index}] должен быть отображением" unless range.is_a?(Hash)

      validate_integer!(range, 'from', "amount_ranges[#{index}].from", allow_nil: false)
      validate_integer!(range, 'to', "amount_ranges[#{index}].to", allow_nil: true)
      validate_prefer!(range, index)
    end

    def self.validate_prefer!(range, index)
      prefer = range['prefer']
      return if prefer.is_a?(String) && !prefer.empty?

      raise SchemaError, "amount_ranges[#{index}].prefer обязателен и должен быть строкой"
    end

    def self.validate_obligations!(obligations)
      return if obligations.nil?

      unless obligations.is_a?(Hash)
        raise SchemaError, 'Ключ `obligations` должен быть отображением'
      end

      obligations.each { |provider, rules| validate_obligation_entry!(provider, rules) }
    end

    def self.validate_obligation_entry!(provider, rules)
      raise SchemaError, "obligations.#{provider} должен быть отображением" unless rules.is_a?(Hash)

      validate_obligation_keys!(provider, rules)
      OBLIGATION_KEYS.each do |field|
        next unless rules.key?(field)

        validate_integer!(rules, field, "obligations.#{provider}.#{field}", allow_nil: true)
      end
    end

    def self.validate_obligation_keys!(provider, rules)
      unknown = rules.keys.map(&:to_s) - OBLIGATION_KEYS
      return if unknown.empty?

      raise SchemaError, "obligations.#{provider}: неизвестный ключ #{unknown.join(', ')}; " \
                         "допустимые: #{OBLIGATION_KEYS.join(', ')}"
    end

    def self.validate_rate_limits!(rate_limits)
      return if rate_limits.nil?

      unless rate_limits.is_a?(Hash)
        raise SchemaError, 'Ключ `rate_limits` должен быть отображением'
      end

      rate_limits.each { |provider, limit| validate_rate_limit!(provider, limit) }
    end

    def self.validate_rate_limit!(provider, limit)
      return if limit.is_a?(Integer)

      raise SchemaError, "rate_limits.#{provider} должен быть целым числом, " \
                         "получено: #{limit.inspect}"
    end

    def self.validate_integer!(hash, key, path, allow_nil:)
      value = hash[key]
      return if value.is_a?(Integer)
      return if allow_nil && value.nil?

      expected = allow_nil ? 'целым числом или null' : 'целым числом'
      raise SchemaError, "#{path} должен быть #{expected}, получено: #{value.inspect}"
    end

    private_class_method :validate_amount_range_entry!, :validate_prefer!,
                         :validate_obligation_entry!, :validate_obligation_keys!,
                         :validate_rate_limit!, :validate_integer!
  end
end
