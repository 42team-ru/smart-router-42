# frozen_string_literal: true

module Offline
  Metrics = Data.define(:max_deviation_num, :delivered, :total, :counts) do
    def max_deviation_pp
      return 0.0 if total.zero?

      Rational(max_deviation_num, total * 100).to_f.round(1)
    end

    def key
      [-delivered, max_deviation_num]
    end

    def to_block
      { 'max_deviation_pp' => max_deviation_pp, 'delivered' => delivered }
    end
  end
end
