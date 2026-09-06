# frozen_string_literal: true

require 'yaml'

module Io
  # Накладывает override из config/routing.yml (`obligations`, `rate_limits`)
  # поверх значений снапшота провайдеров. Источник правды — снапшот, конфиг
  # только перекрывает то, что в нём явно задано; отсутствующий ключ оставляет
  # снапшотное значение как есть (в том числе nil).
  #
  # Domain::Provider — Data, поэтому #with возвращает новый объект: вход не
  # мутируется, порядок провайдеров сохраняется.
  module ProviderOverrides
    OBLIGATION_FIELDS = %w[daily_turnover_min daily_turnover_max].freeze
    EXTRA_FIELDS = %w[volume_share_pct requests_per_minute_limit daily_turnover_min
                      daily_turnover_max].freeze

    # Дополнительные поля живут отдельно от снапшота организаторов: это
    # позволяет подменить --providers чужим JSON, не теряя наши четыре поля.
    # Формат: providers: { vipay: { volume_share_pct: 40, ... } }.
    def self.load_extra(path)
      raw = YAML.safe_load_file(path, permitted_classes: [], aliases: false)
      providers = raw.fetch('providers', raw)
      validate_extra!(providers)
      providers
    rescue Errno::ENOENT
      raise "Файл дополнительных полей провайдеров не найден: #{path}"
    rescue Psych::SyntaxError => e
      raise "Битый YAML дополнительных полей #{path}: #{e.message}"
    end

    # obligations: {"payflow" => {"daily_turnover_min" => 2_000_000}, ...}
    # rate_limits: {"vipay" => 7, ...}
    def self.apply(providers, obligations: {}, rate_limits: {}, providers_overrides: {})
      check_known_providers!(providers, obligations, 'obligations')
      check_known_providers!(providers, rate_limits, 'rate_limits')
      check_known_providers!(providers, providers_overrides, 'providers')

      providers.map { |provider| apply_to(provider, obligations, rate_limits, providers_overrides) }
    end

    def self.apply_to(provider, obligations, rate_limits, providers_overrides)
      attributes = obligation_attributes(provider, obligations)
                   .merge(rate_limit_attributes(provider, rate_limits))
                   .merge(provider_attributes(provider, providers_overrides))
      attributes.empty? ? provider : provider.with(**attributes)
    end
    private_class_method :apply_to

    def self.obligation_attributes(provider, obligations)
      rule = obligations[provider.name]
      return {} if rule.nil?

      OBLIGATION_FIELDS.each_with_object({}) do |field, attributes|
        attributes[field.to_sym] = rule[field] if rule.key?(field)
      end
    end
    private_class_method :obligation_attributes

    def self.rate_limit_attributes(provider, rate_limits)
      return {} unless rate_limits.key?(provider.name)

      { requests_per_minute_limit: rate_limits[provider.name] }
    end
    private_class_method :rate_limit_attributes

    def self.provider_attributes(provider, providers_overrides)
      rule = providers_overrides[provider.name]
      return {} if rule.nil?

      rule.transform_keys(&:to_sym)
    end
    private_class_method :provider_attributes

    def self.validate_extra!(overrides)
      unless overrides.is_a?(Hash)
        raise 'providers_extra должен быть отображением провайдер -> поля'
      end

      overrides.each do |name, fields|
        unknown = fields.is_a?(Hash) ? fields.keys - EXTRA_FIELDS : EXTRA_FIELDS
        next if unknown.empty?

        raise "providers_extra.#{name}: неизвестные или неверные поля #{unknown.join(', ')}"
      end
    end
    private_class_method :validate_extra!

    # Опечатка в имени провайдера в конфиге не должна тихо становиться мёртвым
    # правилом — падаем с отсортированным списком имён, иначе текст ошибки
    # зависит от порядка ключей YAML.
    def self.check_known_providers!(providers, rules, key)
      return if rules.empty?

      known_names = providers.map(&:name)
      unknown = rules.keys.reject { |name| known_names.include?(name) }
      return if unknown.empty?

      raise "конфиг: #{key} для неизвестного провайдера #{unknown.sort.join(', ')}"
    end
    private_class_method :check_known_providers!
  end
end
