# frozen_string_literal: true

require 'domain/provider'
require 'domain/operation'

# Хелпер спеков: Data.define требует все поля разом, без фабрики каждый спек
# превращается в двадцать строк шума. В lib/ не переезжает никогда.
module ProviderFactory
  # Дефолты — провайдер vipay из reference/data/providers.json.
  PROVIDER_DEFAULTS = {
    payment_system: 'vipay',
    status: 'active',
    traffic_percentage: 40,
    priority: 1,
    limit_amount_min: 1000,
    limit_amount_max: 100_000,
    daily_amount_limit: 5_000_000,
    daily_approved_amount: 3_200_000,
    in_progress_count_limit: 10,
    in_progress_count: 4,
    in_progress_amount_limit: 1_000_000,
    in_progress_amount: 380_000,
    available_requisites: 12,
    conversion_24h: 0.87,
    avg_latency_sec: 38,
    banks: %w[sberbank tinkoff vtb],
    exclude_banks: false,
    provider_margin_pct: 1.2,
    merchant_margin_pct: 1.5,
    allow_negative_agreement: false,
    volume_share_pct: nil,
    requests_per_minute_limit: nil,
    daily_turnover_min: nil,
    daily_turnover_max: nil
  }.freeze

  # Дефолты — операция op_101 из reference/data/operations_queue_10.json.
  OPERATION_DEFAULTS = {
    operation_id: 'op_101',
    created_at: '2026-07-30T09:05:00+03:00',
    amount: 15_000,
    bank: 'sberbank',
    card_brand: nil,
    payout_requisite: {}
  }.freeze

  module_function

  def build_provider(**overrides)
    Domain::Provider.new(**PROVIDER_DEFAULTS, **overrides)
  end

  def build_operation(**overrides)
    Domain::Operation.new(**OPERATION_DEFAULTS, **overrides)
  end
end
