# frozen_string_literal: true

module Execution
  # Итог прохода по каскаду.
  #   selected — Domain::Provider, попавший в selected_provider
  #   attempts — Array<Routing::Attempt> в порядке рассмотрения
  #   result   — :approved | :rejected | :expired
  Outcome = Data.define(:selected, :attempts, :result)
end
