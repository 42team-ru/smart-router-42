# frozen_string_literal: true

# rubocop:disable Metrics/MethodLength

module Config
  # Временные CLI-правки raw YAML. Путь обязан существовать: создание нового
  # ключа превращает опечатку в убедительную, но неработающую настройку.
  module Overrides
    PROVIDER_FIELDS = %w[traffic_percentage volume_share_pct daily_amount_limit conversion_24h
                         priority].freeze

    def self.apply(raw, expressions, warn: $stderr)
      expressions.each { |expression| apply_one(raw, expression, warn) }
      raw
    end

    def self.apply_one(raw, expression, warn)
      path, value = expression.split('=', 2)
      return warning(warn, expression, 'ожидается key=value') if value.nil? || path.empty?

      keys = path.split('.')
      return apply_provider(raw, keys, value, expression, warn) if keys.first == 'providers'

      parent, key = find_parent(raw, keys)
      if parent.nil? || !parent.key?(key)
        return warning(warn, expression,
                       'такого ключа в базовом конфиге нет')
      end

      parent[key] = parse(value)
      parent
    end
    private_class_method :apply_one

    def self.apply_provider(raw, keys, value, expression, warn)
      unless keys.size == 3 && PROVIDER_FIELDS.include?(keys[2])
        return warning(warn, expression,
                       'разрешены только providers.<name>.<field>')
      end

      name = keys[1]
      field = keys[2]
      bucket = provider_bucket(raw, name)
      return warning(warn, expression, "провайдер #{name} не задан в конфиге") if bucket.nil?

      bucket[field] = parse(value)
    end
    private_class_method :apply_provider

    # providers.* в YAML представлены существующими blocks obligations и
    # rate_limits. Для остальных allowlist-полей создаётся явный providers
    # overlay, который точка входа накладывает на snapshot после загрузки.
    def self.provider_bucket(raw, name)
      raw['providers'] ||= {}
      raw['providers'][name] ||= {}
    end
    private_class_method :provider_bucket

    def self.find_parent(raw, keys)
      parent = keys[0...-1].reduce(raw) { |node, key| node.is_a?(Hash) ? node[key] : nil }
      [parent, keys.last]
    end
    private_class_method :find_parent

    def self.parse(value)
      return true if value == 'true'
      return false if value == 'false'
      return nil if value == 'null'
      return Integer(value, 10) if value.match?(/\A-?\d+\z/)
      return Float(value) if value.match?(/\A-?\d+\.\d+\z/)

      value
    end
    private_class_method :parse

    def self.warning(warn, expression, reason)
      warn.puts "warning: --set #{expression.inspect}: #{reason}"
    end
    private_class_method :warning
  end
end
# rubocop:enable Metrics/MethodLength
