# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize

module Reporting
  module ConversionCheck
    def self.build(providers, history)
      providers.to_h { |provider| [provider.name, entry(provider, history)] }
    end

    def self.entry(provider, history)
      declared = provider.conversion_24h
      observed = history.known?(provider.name) ? history.approved_ratio(provider.name) : nil
      used = history.known?(provider.name) ? history.approved_ratio(provider.name) : declared
      { 'declared' => declared, 'observed_history' => observed, 'used_estimate' => used,
        'observations' => history.known?(provider.name) ? history.observations(provider.name) : 0,
        'gap_pp' => declared.nil? || observed.nil? ? nil : ((observed - declared) * 100).round(1) }
    end
    private_class_method :entry
  end
end
# rubocop:enable Metrics/AbcSize
