# frozen_string_literal: true

module Execution
  module OutcomeSource
    # Источник исхода попытки. Чистая функция, детерминированная по своим аргументам:
    # два прогона одного входа обязаны дать побайтово одинаковый вывод.
    # Реализации: Deterministic (хеш от seed), Scripted (сценарий из YAML),
    # AlwaysOk / AlwaysFail (вырожденные случаи).
    class Base
      def call(operation, provider, attempt_no)
        raise NotImplementedError, "#{self.class}#call"
      end
    end
  end
end
