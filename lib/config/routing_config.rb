# frozen_string_literal: true

module Config
  # CFG-1: типизированный результат Config::Loader.load. Только данные, уже
  # прошедшие валидацию схемы — никакой логики. Подключение в пайплайн (CFG-2)
  # и семантика полей (какая стратегия/слои реально существуют) — не здесь.
  RoutingConfig = Data.define(
    :strategy, :layers, :allocator, :outcomes,
    :amount_ranges, :obligations, :rate_limits, :fallback_provider
  )
end
