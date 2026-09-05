# frozen_string_literal: true

require_relative 'errors'
require_relative '../io/queue_loader'
require_relative '../io/providers_loader'

module Api
  # Ручная валидация payload'ов. Опирается на существующие лоадеры ядра
  # (Io::QueueLoader::Builder для операций, Io::ProvidersLoader для провайдеров)
  # — не дублируем правила, только маппим их в API-формат ошибок.
  module Validators
    OPERATION_REQUIRED = Io::QueueLoader::REQUIRED_FIELDS

    SNAPSHOT_REQUIRED = %w[gateway merchant providers].freeze
    CONFIG_REQUIRED = %w[strategy outcomes fallback_provider].freeze

    def self.operation!(payload)
      unless payload.is_a?(Hash)
        raise Errors::ValidationFailed.new(
          'Operation payload must be a JSON object',
          { missing: ['operation'] }
        )
      end

      op = payload['operation']
      unless op.is_a?(Hash)
        raise Errors::ValidationFailed.new(
          'Missing required field "operation"', { missing: ['operation'] }
        )
      end

      check_operation_shape!(op)
      op
    end

    def self.operations_batch!(payload)
      unless payload.is_a?(Hash)
        raise Errors::ValidationFailed.new(
          'Batch payload must be a JSON object', { missing: ['operations'] }
        )
      end

      arr = payload['operations']
      unless arr.is_a?(Array) && !arr.empty?
        raise Errors::ValidationFailed.new(
          'Field "operations" must be a non-empty array',
          { missing: ['operations'] }
        )
      end
      arr
    end

    def self.snapshot!(payload)
      unless payload.is_a?(Hash)
        raise Errors::ValidationFailed.new(
          'Snapshot must be a JSON object', { invalid: ['payload'] }
        )
      end

      missing = SNAPSHOT_REQUIRED.reject { |field| payload[field] }
      if missing.any?
        raise Errors::ValidationFailed.new(
          "Snapshot missing required fields: #{missing.join(', ')}",
          { missing: missing }
        )
      end

      providers = payload['providers']
      unless providers.is_a?(Array) && !providers.empty?
        raise Errors::ValidationFailed.new(
          '"providers" must be a non-empty array', { invalid: [{ field: 'providers' }] }
        )
      end
      payload
    end

    def self.config!(payload)
      unless payload.is_a?(Hash)
        raise Errors::ValidationFailed.new(
          'Config request must be a JSON object', { missing: ['config'] }
        )
      end

      cfg = payload['config']
      unless cfg.is_a?(Hash)
        raise Errors::ValidationFailed.new(
          'Missing required field "config"', { missing: ['config'] }
        )
      end

      missing = CONFIG_REQUIRED.reject { |field| cfg[field] }
      if missing.any?
        raise Errors::ValidationFailed.new(
          "Config missing required fields: #{missing.join(', ')}",
          { missing: missing }
        )
      end
      cfg
    end

    def self.bootstrap!(payload)
      unless payload.is_a?(Hash)
        raise Errors::ValidationFailed.new(
          'Bootstrap must be a JSON object',
          { missing: %w[snapshot config] }
        )
      end

      missing = %w[snapshot config].reject { |field| payload[field] }
      if missing.any?
        raise Errors::ValidationFailed.new(
          "Bootstrap missing required fields: #{missing.join(', ')}",
          { missing: missing }
        )
      end

      snapshot!(payload['snapshot'])
      config!('config' => payload['config'])
      payload
    end

    def self.check_operation_shape!(op)
      invalid = []
      missing = OPERATION_REQUIRED.reject { |field| op.key?(field) && !op[field].nil? }
      if missing.any?
        raise Errors::ValidationFailed.new(
          "Operation missing required fields: #{missing.join(', ')}",
          { missing: missing }
        )
      end

      return if op['amount'].is_a?(Integer) && op['amount'].positive?

      invalid << { field: 'amount', code: 'not_positive_integer', got: op['amount'] }
      raise Errors::ValidationFailed.new('Operation payload invalid', { invalid: invalid })
    end
  end
end
