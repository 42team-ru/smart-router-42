# frozen_string_literal: true

module Api
  # Исключения API-слоя. Каждому соответствует стабильный код и HTTP-статус
  # из docs/openapi.yaml (schema Error).
  module Errors
    class ApiError < StandardError
      def http_status
        500
      end

      def code
        'internal_error'
      end

      def details
        nil
      end

      def to_body
        body = { 'error' => code, 'message' => message }
        body['details'] = details if details
        body
      end
    end

    class ValidationFailed < ApiError
      attr_reader :details

      def initialize(message, details = nil)
        super(message)
        @details = details
      end

      def http_status = 400
      def code = 'validation_failed'
    end

    class NoSnapshot < ApiError
      def initialize(message = 'Call POST /snapshot or POST /bootstrap first')
        super
      end

      def http_status = 409
      def code = 'no_snapshot'
    end

    class NotFound < ApiError
      def http_status = 404
      def code = 'not_found'
    end
  end
end
