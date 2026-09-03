# frozen_string_literal: true

require_relative 'attempt'

module Routing
  # Результат сработавшей hard-проверки.
  #   reason  — строка из Reasons::SKIP, дословно.
  #   details — человекочитаемое сравнение, ОБЯЗАНО содержать число:
  #             "52000 > limit_amount_max 50000". Причина без числа не принимается.
  Violation = Data.define(:reason, :details) do
    def to_attempt(provider)
      Attempt.new(provider: provider, decision: 'skipped', reason: reason, details: details)
    end
  end
end
