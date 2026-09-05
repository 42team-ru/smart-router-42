# frozen_string_literal: true

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

    # obligations: {"payflow" => {"daily_turnover_min" => 2_000_000}, ...}
    # rate_limits: {"vipay" => 7, ...}
    def self.apply(providers, obligations: {}, rate_limits: {})
      check_known_providers!(providers, obligations, 'obligations')
      check_known_providers!(providers, rate_limits, 'rate_limits')

      providers.map { |provider| apply_to(provider, obligations, rate_limits) }
    end

    def self.apply_to(provider, obligations, rate_limits)
      attributes = obligation_attributes(provider, obligations)
                   .merge(rate_limit_attributes(provider, rate_limits))
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
