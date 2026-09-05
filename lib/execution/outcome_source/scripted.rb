# frozen_string_literal: true

require 'yaml'
require_relative 'base'

module Execution
  module OutcomeSource
    # Сценарный источник исходов для тестов и демо. Каждая пара (op_id, provider)
    # имеет заранее заданный исход. Промах ключа — KeyError, а не «по умолчанию
    # отказ»: тихий дефолт скроет ошибку в сценарии.
    #
    # Формат YAML:
    #   op_101:
    #     vipay: :approved
    #     payflow: :rejected
    #   op_102:
    #     vipay: :expired
    class Scripted < Base
      ALLOWED = %i[approved rejected expired].freeze

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
        outcome = by_provider.fetch(provider.name) do
          raise KeyError, "нет исхода для (#{operation.operation_id}, #{provider.name})"
        end
        normalize(outcome)
      end

      private

      # Сценарий приходит из двух мест с разной типизацией: отдельный YAML
      # грузится с permitted_classes: [Symbol] и даёт :approved, а сценарий,
      # вписанный в config/routing.yml, проходит через общий загрузчик конфига
      # без Symbol и даёт "approved". Для вызывающей стороны это один и тот же
      # исход, поэтому приводим здесь, а не заставляем автора сценария помнить,
      # где двоеточие обязательно.
      def normalize(outcome)
        symbol = outcome.to_sym
        return symbol if ALLOWED.include?(symbol)

        raise KeyError, "недопустимый исход #{outcome.inspect}; допустимы #{ALLOWED.join(', ')}"
      end
    end
  end
end
