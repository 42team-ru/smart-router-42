# frozen_string_literal: true

require 'digest'
require_relative 'base'

module Execution
  module OutcomeSource
    # Исход определяется хешем seed, операции, провайдера и номера попытки.
    #   roll = SHA256("seed:op_id:name:attempt_no").to_i(16) % 10_000
    #   approved_bp/rejected_bp — целые базисные пункты на провайдера (см.
    #   outcome_table ниже)
    #   roll < approved_bp                        -> :approved
    #   roll < approved_bp + rejected_bp           -> :rejected
    #   иначе                                      -> :expired
    #
    # outcome_table содержит пороги approved/rejected в базисных пунктах.
    class Deterministic < Base
      BASIS_POINTS = 10_000

      # Для неизвестного провайдера: 5% rejected, остальное expired.
      DEFAULT_OUTCOME = { approved_bp: 0, rejected_bp: 500 }.freeze

      # В паспортном режиме 5% неодобренных операций считаются rejected.
      PASSPORT_REJECTED_BP = 500

      def initialize(seed:, outcome_table:)
        super()
        @seed = seed
        @outcome_table = outcome_table
      end

      def call(operation, provider, attempt_no)
        key = "#{@seed}:#{operation.operation_id}:#{provider.name}:#{attempt_no}"
        roll = Digest::SHA256.hexdigest(key).to_i(16) % BASIS_POINTS
        bp = @outcome_table.fetch(provider.name, DEFAULT_OUTCOME)

        return :approved if roll < bp.fetch(:approved_bp)
        return :rejected if roll < bp.fetch(:approved_bp) + bp.fetch(:rejected_bp)

        :expired
      end

      # Паспортный режим (outcomes.calibrate_from_history: false): approved_bp
      # строго из conversion_24h снапшота, без всякой истории. Единственное
      # умножение на Float здесь — перевод уже готовой паспортной доли в целые
      # базисные пункты один раз при сборке таблицы, а не при каждом броске;
      # сам #call выше работает только с целыми числами.
      def self.passport_outcome_table(providers, rejected_bp: PASSPORT_REJECTED_BP)
        providers.to_h do |provider|
          approved_bp = (provider.conversion_24h.to_f * BASIS_POINTS).round
          [provider.name, { approved_bp: approved_bp, rejected_bp: rejected_bp }]
        end
      end
    end
  end
end
