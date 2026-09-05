# frozen_string_literal: true

require_relative 'base'
require_relative '../violation'
require_relative '../details'

module Routing
  module Constraints
    # Отсекает провайдера, который не работает с банком получателя.
    #
    # У провайдера есть договорённости не со всеми банками сразу: где-то нет
    # канала, где-то запретительные тарифы. Один и тот же список банков читается
    # двумя способами, и режим задаёт флаг exclude_banks: по умолчанию это белый
    # список (работаем только с перечисленными), с флагом — чёрный (работаем со
    # всеми, кроме перечисленных).
    #
    # Пустой список означает «ограничений нет» в обоих режимах: провайдер
    # принимает любой банк. Именно так устроен quickpay, и поэтому он оказывается
    # единственным допустимым для заявок из банков, с которыми не работают
    # остальные — на публичной очереди это половина причин, по которым целевое
    # распределение недостижимо.
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
