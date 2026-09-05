# frozen_string_literal: true

module Config
  # CFG-1: типизированный результат Config::Loader.load. Только данные, уже
  # прошедшие валидацию схемы — никакой логики. Подключение в пайплайн (CFG-2)
  # и семантика полей (какая стратегия/слои реально существуют) — не здесь.
  # cascade по умолчанию {} -- П7 (docs/plans/P6/P7_настраиваемый_fallback.md)
  # добавил поле поверх уже существующих построителей RoutingConfig в спеках
  # (assembly/selector/strategies), которые его не знают; дефолт здесь, а не
  # обязательный keyword, сохраняет их рабочими без правки. comparison по
  # умолчанию [] -- П4 (docs/plans/P6/P4_сравнение.md) добавил список офлайн-
  # вариантов сравнения тем же приёмом.
  # Путь к истории операций по умолчанию. Значение то же, что раньше было
  # зашито константой внутри стратегии conversion и в bin/route.
  DEFAULT_HISTORY_PATH = 'reference/data/operations_history.csv'

  RoutingConfig = Data.define(
    :strategy, :layers, :goals, :strategy_selection, :outcomes,
    :amount_ranges, :obligations, :rate_limits, :fallback_provider, :cascade, :comparison,
    :history_path
  ) do
    def initialize(cascade: {}, comparison: [], history_path: DEFAULT_HISTORY_PATH, **rest)
      super
    end
  end
end
