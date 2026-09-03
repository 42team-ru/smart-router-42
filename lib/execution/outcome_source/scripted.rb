# frozen_string_literal: true

require 'yaml'
require_relative 'base'

module Execution
  module OutcomeSource
    # Сценарный источник исходов для тестов и демо. Каждая пара (op_id, provider)
    # имеет заранее заданный исход. Промах ключа — KeyError, а не «по умолчанию
    # отказ»: тихий дефолт скроет ошибку в сценарии.
    #
    # Формат YAML (docs/ARCHITECTURE.md §7):
    #   op_101:
    #     vipay: :approved
    #     payflow: :rejected
    #   op_102:
    #     vipay: :expired
    class Scripted < Base
      def self.load(path)
        script = YAML.safe_load_file(path, permitted_classes: [Symbol])
        new(script: script)
      end

      def initialize(script:)
        super()
        @script = script
      end

      def call(operation, provider, _attempt_no)
        by_provider = @script.fetch(operation.operation_id) do
          raise KeyError, "нет исхода для операции #{operation.operation_id}"
        end
        by_provider.fetch(provider.name) do
          raise KeyError, "нет исхода для (#{operation.operation_id}, #{provider.name})"
        end
      end
    end
  end
end
