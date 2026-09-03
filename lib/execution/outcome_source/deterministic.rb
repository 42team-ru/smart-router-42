# frozen_string_literal: true

require 'digest'
require_relative 'base'

module Execution
  module OutcomeSource
    # Детерминированный источник исходов: хеш от seed и идентификаторов вместо
    # генератора псевдослучайных чисел. Два прогона одного входа обязаны дать
    # побайтово одинаковый вывод — источники недетерминизма в решающем пути
    # запрещены (греп в CI, см. scripts/check_determinism.sh).
    #
    # Формула из docs/ARCHITECTURE.md §7:
    #   roll = SHA256("seed:op_id:name:attempt_no").to_i(16) % 10_000
    #   threshold = (conversions[name] * 10_000).round
    #   roll < threshold                       -> :approved
    #   roll < threshold + reject_share        -> :rejected
    #   иначе                                  -> :expired
    #
    # reject_share — доля отказов среди неодобренных, в базисных пунктах.
    # По умолчанию 500 бп (5%): согласовано в ревью Ф1, вынесено параметром,
    # чтобы сценарные тесты каскада могли двигать соотношение rejected/expired.
    class Deterministic < Base
      BASIS_POINTS = 10_000

      def initialize(seed:, conversions:, reject_share: 500)
        super()
        @seed = seed
        @conversions = conversions
        @reject_share = reject_share
      end

      def call(operation, provider, attempt_no)
        key = "#{@seed}:#{operation.operation_id}:#{provider.name}:#{attempt_no}"
        roll = Digest::SHA256.hexdigest(key).to_i(16) % BASIS_POINTS
        threshold = (@conversions.fetch(provider.name) * BASIS_POINTS).round

        return :approved if roll < threshold
        return :rejected if roll < threshold + @reject_share

        :expired
      end
    end
  end
end
