# frozen_string_literal: true

module Reporting
  # Исторические исходы вынесены отдельно, чтобы не смешивать их с симуляцией очереди.
  module OutcomeDistribution
    RESULTS = %w[approved rejected expired].freeze

    def self.build(history, source)
      total = entry(history.providers.sum { |name| history.observations(name) }, history, nil)
      by_provider = history.providers.sort.to_h do |name|
        [name, entry(history.observations(name), history, name)]
      end
      {
        'source' => source,
        'definition' => 'Исторические наблюдения по операциям, а не исходы текущей очереди.',
        'total' => total,
        'by_provider' => by_provider
      }
    end

    def self.entry(observations, history, provider)
      counts = RESULTS.to_h do |result|
        count = if provider
                  history.public_send("#{result}_count",
                                      provider)
                else
                  total_count(history, result)
                end
        [result, { 'count' => count, 'share_pct' => percentage(count, observations) }]
      end
      { 'observations' => observations }.merge(counts)
    end
    private_class_method :entry

    def self.total_count(history, result)
      history.providers.sum { |name| history.public_send("#{result}_count", name) }
    end
    private_class_method :total_count

    def self.percentage(part, total)
      return 0.0 if total.zero?

      Rational(part * 100, total).round(1).to_f
    end
    private_class_method :percentage
  end
end
