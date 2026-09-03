# frozen_string_literal: true

module Routing
  module Constraints
    # Hard-constraint: отвечает на вопрос «можно ли вообще», а не «кого предпочесть».
    # Одна проверка — один файл — одна причина.
    # Возвращает nil, если провайдер проходит, иначе Routing::Violation.
    # nil в поле лимита = ограничения нет = проверка не срабатывает.
    class Base
      def self.violation(provider, operation, state)
        raise NotImplementedError, "#{name}.violation"
      end
    end
  end
end
