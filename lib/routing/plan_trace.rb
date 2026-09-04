# frozen_string_literal: true

module Routing
  # Объяснение порядка каскада до исполнения. Формат attempts не расширяется:
  # сегменты складываются в существующее details через неизменяемый разделитель.
  PlanTrace = Data.define(:strategy_name, :segments) do
    def details = segments.join(' | ')
  end
end
