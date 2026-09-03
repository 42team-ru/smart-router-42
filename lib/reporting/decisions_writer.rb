# frozen_string_literal: true

require 'json'

module Reporting
  # A-1: сборка routing_decisions.json из уже готовых решений.
  #
  # Здесь нет логики допуска или каскада — только форма файла. Вход:
  # пары (Domain::Operation, Execution::Outcome), уже посчитанные
  # Routing (RoutePlan/Violation) и Execution (Outcome).
  module DecisionsWriter
    def self.build_decision(operation, outcome)
      {
        'operation_id' => operation.operation_id,
        'selected_provider' => outcome.selected.name,
        'attempts' => outcome.attempts.map(&:to_h),
        'simulated_result' => outcome.result.to_s,
        'latency_sec' => outcome.selected.avg_latency_sec
      }
    end

    def self.build(pairs)
      pairs.map { |operation, outcome| build_decision(operation, outcome) }
    end

    # Правило воспроизводимости: File.write, а не File.open+puts, и один
    # завершающий перевод строки — иначе make determinism будет мигать.
    def self.write(path, pairs)
      File.write(path, "#{JSON.pretty_generate(build(pairs))}\n")
    end
  end
end
