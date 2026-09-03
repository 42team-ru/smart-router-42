# frozen_string_literal: true

require 'domain/provider'
require 'domain/operation'

# Хелперы построения тестовых Domain-объектов. Общие для всех спеков зоны
# Execution & State. Все поля Provider — с nil-дефолтами; тест задаёт только
# те, которые ему важны, и не тонет в шуме имён полей.
module BuildHelpers
  PROVIDER_DEFAULTS = {
    status: 'active', traffic_percentage: 0, priority: 1,
    limit_amount_min: nil, limit_amount_max: nil,
    daily_amount_limit: nil, daily_approved_amount: 0,
    in_progress_count_limit: nil, in_progress_count: 0,
    in_progress_amount_limit: nil, in_progress_amount: 0,
    available_requisites: 0, conversion_24h: nil, avg_latency_sec: nil,
    banks: nil, exclude_banks: nil,
    provider_margin_pct: nil, merchant_margin_pct: nil, allow_negative_agreement: nil,
    volume_share_pct: nil, requests_per_minute_limit: nil,
    daily_turnover_min: nil, daily_turnover_max: nil
  }.freeze

  def build_provider(name, **overrides)
    Domain::Provider.new(payment_system: name, **PROVIDER_DEFAULTS, **overrides)
  end

  def build_spacepayments(**overrides)
    build_provider('spacepayments', priority: 99, available_requisites: 8, **overrides)
  end

  OPERATION_DEFAULTS = {
    created_at: '2026-07-30T10:00:00Z', amount: 10_000,
    bank: 'sberbank', card_brand: 'visa', payout_requisite: 'card'
  }.freeze

  def build_operation(id: 'op_1', **overrides)
    Domain::Operation.new(operation_id: id, **OPERATION_DEFAULTS, **overrides)
  end
end

RSpec.configure { |c| c.include BuildHelpers }
