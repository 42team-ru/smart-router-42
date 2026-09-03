# frozen_string_literal: true

require_relative 'base'

module Execution
  module OutcomeSource
    # Вырожденный источник для тестов каскада: любая попытка успешна.
    # Позволяет проверить путь «первый провайдер одобрил» без сценарной YAML.
    class AlwaysOk < Base
      def call(_operation, _provider, _attempt_no) = :approved
    end
  end
end
