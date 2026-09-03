# frozen_string_literal: true

require_relative 'base'
require_relative '../violation'
require_relative '../details'

module Routing
  module Constraints
    # R-7: отрицательная маржа возможна лишь при явном соглашении. Проценты
    # сравниваются рационально, чтобы JSON-десятичные значения не шли через
    # неточный Float-сравнитель.
    class Margin < Base
      REASON = 'negative_margin'

      def self.violation(provider, _operation, _state)
        provider_margin = provider.provider_margin_pct
        merchant_margin = provider.merchant_margin_pct
        return nil if provider_margin.nil? || merchant_margin.nil?
        return nil if provider.allow_negative_agreement
        return nil unless Rational(provider_margin.to_s) > Rational(merchant_margin.to_s)

        Violation.new(
          reason: REASON,
          details: Details.negative_margin(provider_margin, merchant_margin)
        )
      end
    end
  end
end
