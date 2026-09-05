# frozen_string_literal: true

require_relative '../reporting/decisions_writer'

module Api
  # Domain-объекты -> JSON-ready Hash. Форма ответов зафиксирована
  # docs/openapi.yaml. Форма decision совпадает с Reporting::DecisionsWriter,
  # так что переиспользуем его.
  module Serializers
    SCALE_BP = 10_000

    def self.decision(operation, outcome)
      Reporting::DecisionsWriter.build_decision(operation, outcome)
    end

    def self.state(gateway:, merchant:, strategy:, seed:, providers:, state:)
      total = state.total_count_units
      {
        'gateway' => gateway,
        'merchant' => merchant,
        'strategy' => strategy,
        'seed' => seed,
        'providers' => providers.map { |provider| provider_state(provider, state, total) }
      }
    end

    def self.provider_state(provider, state, total)
      name = provider.name
      {
        'payment_system' => name,
        'in_progress_count' => state.in_progress_count(name),
        'in_progress_amount' => state.in_progress_amount(name),
        'daily_approved_amount' => state.daily_approved_amount(name),
        'available_requisites' => state.available_requisites(name),
        'share_bp' => total.zero? ? 0 : (state.count_units(name) * SCALE_BP / total)
      }
    end

    def self.context_ok(providers_count:, gateway:, merchant:, strategy:)
      {
        'status' => 'ok',
        'providers_count' => providers_count,
        'gateway' => gateway,
        'merchant' => merchant,
        'strategy' => strategy
      }
    end
  end
end
