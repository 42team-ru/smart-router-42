# frozen_string_literal: true

require 'json'
require_relative '../domain/operation'

module Io
  # IO-2: загрузчик очереди операций + валидация полей.
  #
  # Битая запись (нет обязательного поля, amount не целое положительное
  # число) откладывается в errors, прогон продолжается. Дубль operation_id —
  # тоже в errors, сохраняется первое вхождение (см. ARCHITECTURE.md §16).
  module QueueLoader
    Result = Data.define(:operations, :errors)

    REQUIRED_FIELDS = %w[operation_id created_at amount bank payout_requisite].freeze

    def self.load(path)
      Builder.new(parse(path)).call
    end

    def self.parse(path)
      JSON.parse(File.read(path))
    rescue Errno::ENOENT
      raise "Файл очереди не найден: #{path}"
    rescue JSON::ParserError => e
      raise "Битый JSON в файле очереди #{path}: #{e.message}"
    end

    # Разбирает сырые записи очереди по одной: валидные превращает в
    # Domain::Operation, битые и дублирующиеся operation_id откладывает
    # в errors без падения на всей очереди.
    class Builder
      def initialize(raw_queue)
        @raw_queue = raw_queue
        @operations = []
        @errors = []
        @seen_ids = {}
      end

      def call
        @raw_queue.each_with_index { |raw, index| process(raw, index) }
        Result.new(operations: @operations, errors: @errors)
      end

      private

      def process(raw, index)
        reason = rejection_reason(raw)
        return @errors << "operation[#{index}]: #{reason}" if reason
        return @errors << duplicate_message(raw, index) if @seen_ids[raw['operation_id']]

        @seen_ids[raw['operation_id']] = true
        @operations << build_operation(raw)
      end

      def duplicate_message(raw, index)
        "operation[#{index}]: дубль operation_id #{raw['operation_id']}, оставлено первое решение"
      end

      def rejection_reason(raw)
        missing = REQUIRED_FIELDS.reject { |field| raw[field] }
        return "нет обязательного поля #{missing.join(', ')}" if missing.any?
        return amount_error(raw['amount']) unless valid_amount?(raw['amount'])

        nil
      end

      def amount_error(amount)
        "amount должен быть положительным целым числом, получено #{amount.inspect}"
      end

      def valid_amount?(amount)
        amount.is_a?(Integer) && amount.positive?
      end

      def build_operation(raw)
        Domain::Operation.new(
          operation_id: raw.fetch('operation_id'),
          created_at: raw.fetch('created_at'),
          amount: raw.fetch('amount'),
          bank: raw.fetch('bank'),
          card_brand: raw['card_brand'],
          payout_requisite: raw.fetch('payout_requisite')
        )
      end
    end
  end
end
