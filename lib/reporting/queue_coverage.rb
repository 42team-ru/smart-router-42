# frozen_string_literal: true

module Reporting
  module QueueCoverage
    # rubocop:disable-next Metrics/MethodLength -- все поля выводятся из единого результата загрузки очереди.
    def self.build(queue_result, pairs)
      queue_operations = queue_result.operations.size + queue_result.errors.size
      with_decision = pairs.size
      dropped = queue_operations - with_decision
      {
        'queue_operations' => queue_operations,
        'with_decision' => with_decision,
        'dropped' => dropped,
        'coverage_pct' => percentage(with_decision, queue_operations),
        'dropped_reasons' => queue_result.errors.map do |error|
          error.sub(/\Aoperation\[\d+\]: /, '')
        end
                                         .tally.sort.to_h
      }
    end

    def self.percentage(part, total)
      return 100.0 if total.zero?

      Rational(part * 100, total).round(1).to_f
    end
    private_class_method :percentage
  end
end
