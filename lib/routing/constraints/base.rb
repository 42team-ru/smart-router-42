# frozen_string_literal: true

module Routing
  module Constraints
    # Контракт проверок допуска: nil — прошёл, Routing::Violation — нет.
    # Причина из Reasons::SKIP, объяснение содержит числа.
    #
    # Отсутствующий лимит значит «ограничения нет», а не ноль: так устроен
    # fallback-провайдер. Отсутствующий статус или реквизиты — наоборот, отсев.
    class Base
      def self.violation(provider, operation, state)
        raise NotImplementedError, "#{name}.violation"
      end
    end
  end
end
