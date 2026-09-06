# frozen_string_literal: true

require_relative 'recommendations'
require_relative '../offline/comparison'

module Reporting
  # Проверяем совет тем же онлайн-проходом, но на независимом состоянии.
  module RecommendationEffect
    def self.build(pairs, operations:, providers:, config:, history:)
      recommendations = Recommendations.build_detailed(pairs, providers, history)
      applicable = recommendations.select { |item| item['provider'] && item['suggested'] }
      return { 'applied' => [], 'note' => 'применимых параметрических рекомендаций нет' } if applicable.empty?

      changed = apply(providers, applicable)
      before = Offline::Comparison.evaluate(operations: operations, providers: providers,
                                            config: config, history: history)
      after = Offline::Comparison.evaluate(operations: operations, providers: changed,
                                           config: config, history: history)
      { 'applied' => applicable.map { |item| item.slice('code', 'provider', 'param', 'current', 'suggested') },
        'before' => before, 'after' => after,
        'delta_max_deviation_pp' => (after['max_deviation_pp'] - before['max_deviation_pp']).round(1),
        'delta_delivered' => after['delivered'] - before['delivered'],
        'note' => Offline::Comparison::NOTE }
    end

    def self.apply(providers, recommendations)
      changes = recommendations.to_h { |item| [[item['provider'], item['param']], item['suggested']] }
      providers.map do |provider|
        attributes = changes.each_with_object({}) do |((name, param), value), result|
          result[param.to_sym] = value if name == provider.name
        end
        attributes.empty? ? provider : provider.with(**attributes)
      end
    end
    private_class_method :apply
  end
end
