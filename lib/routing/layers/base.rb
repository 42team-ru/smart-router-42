# frozen_string_literal: true

module Routing
  module Layers
    # Слой корректирует уже проранжированный список кандидатов.
    # Инвариант: слой не может вернуть в список того, кого отсёк допуск —
    # он только переставляет уже допущенных, ничего не добавляет и не удаляет.
    # Возвращает перестановку ranked того же размера.
    class Base
      def adjust(ranked, operation, state)
        raise NotImplementedError, "#{self.class}#adjust"
      end
    end
  end
end
