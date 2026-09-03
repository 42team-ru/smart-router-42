# frozen_string_literal: true

module Domain
  # Снимок одного провайдера из providers.json на момент операции.
  #
  # ВАЖНО: nil в любом лимите означает «ограничения нет», а не ноль — так
  # устроен spacepayments (у него нет ни одного жёсткого предела). Проверки
  # обязаны трактовать nil именно так, а не как «лимит равен нулю».
  #
  # Поля из снапшота организаторов: payment_system, status, traffic_percentage,
  # priority, limit_amount_min, limit_amount_max, daily_amount_limit,
  # daily_approved_amount, in_progress_count_limit, in_progress_count,
  # in_progress_amount_limit, in_progress_amount, available_requisites,
  # conversion_24h, avg_latency_sec, banks, exclude_banks, provider_margin_pct,
  # merchant_margin_pct, allow_negative_agreement.
  #
  # Поля, которых нет в снапшоте и которые заводим сами (ТЗ разрешает,
  # см. docs/plans/PHASE_0.md, противоречие C-G): volume_share_pct,
  # requests_per_minute_limit, daily_turnover_min, daily_turnover_max.
  # Ограничение, параметра которого нет, не отсеивает никого.
  Provider = Data.define(
    :payment_system, :status, :traffic_percentage, :priority,
    :limit_amount_min, :limit_amount_max,
    :daily_amount_limit, :daily_approved_amount,
    :in_progress_count_limit, :in_progress_count,
    :in_progress_amount_limit, :in_progress_amount,
    :available_requisites, :conversion_24h, :avg_latency_sec,
    :banks, :exclude_banks,
    :provider_margin_pct, :merchant_margin_pct, :allow_negative_agreement,
    :volume_share_pct, :requests_per_minute_limit,
    :daily_turnover_min, :daily_turnover_max
  ) do
    def name
      payment_system
    end
  end
end
