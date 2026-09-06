# frozen_string_literal: true

require_relative 'base'
require_relative '../violation'
require_relative '../details'

module Routing
  module Constraints
    # Отсекает провайдера, который не работает с банком получателя.
    #
    # Флаг exclude_banks задаёт, как читать список: по умолчанию белый,
    # с флагом — чёрный. Пустой список в обоих режимах означает «любой банк»
    # (так устроен quickpay, поэтому он часто оказывается единственным
    # допустимым).
    class BankFilter < Base
      REASON = 'bank_not_in_list'

      def self.violation(provider, operation, _state)
        banks = provider.banks
        return nil if banks.nil? || banks.empty?
        return excluded_bank_violation(operation, banks) if excluded?(provider, operation, banks)
        return nil if provider.exclude_banks == true
        return nil if banks.include?(operation.bank)

        Violation.new(reason: REASON, details: Details.bank_not_allowed(operation.bank, banks))
      end

      def self.excluded?(provider, operation, banks)
        provider.exclude_banks == true && banks.include?(operation.bank)
      end

      def self.excluded_bank_violation(operation, banks)
        Violation.new(
          reason: REASON,
          details: Details.bank_excluded(operation.bank, banks)
        )
      end
    end
  end
end
