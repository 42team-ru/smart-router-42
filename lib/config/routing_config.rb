# frozen_string_literal: true

module Config
  # Типизированный результат Config::Loader.load. Только данные, уже
  # прошедшие валидацию схемы — никакой логики. Подключение в пайплайн и
  # семантика полей (какая стратегия/слои реально существуют) — не здесь.
  # cascade по умолчанию {} и comparison по умолчанию [] -- оба поля добавлены
  # поверх уже существующих построителей RoutingConfig в спеках
  # (assembly/selector/strategies), которые их не знают; дефолт здесь, а не
  # обязательный keyword, сохраняет их рабочими без правки.
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
