# frozen_string_literal: true

require_relative 'base'

module Execution
  module OutcomeSource
    # Вырожденный источник для тестов каскада: любая попытка отказ.
    # Проверяет исчерпание каскада — selected_provider последний реальный,
    # не spacepayments (fallback по допуску, не по исходу).
    class AlwaysFail < Base
      def call(_operation, _provider, _attempt_no) = :rejected
    end
  end
end
