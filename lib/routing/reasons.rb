# frozen_string_literal: true

module Routing
  module Reasons
    # Причины отсева. Дословно из reference/data/reference_decisions.json,
    # валидатор организаторов сверяет их посимвольно. Свои формулировки запрещены.
    SKIP = %w[
      provider_inactive
      zero_traffic_share
      amount_below_minimum
      amount_exceeds_limit
      daily_limit_exceeded
      in_progress_limit_exceeded
      bank_not_in_list
      negative_margin
      no_requisites
      rate_limit_exceeded
    ].freeze

    # Причины выбора. Первые две — из эталонного файла решений организаторов.
    SELECTED = %w[
      only_eligible_provider
      first_eligible
      best_target_adherence
      next_in_cascade
      fallback_no_eligible_provider
      fallback_after_cascade
    ].freeze
  end
end
