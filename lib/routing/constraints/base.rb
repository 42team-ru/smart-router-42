# frozen_string_literal: true

module Routing
  module Constraints
    # Общий контракт проверок допуска: «можно ли отдать заявку этому провайдеру».
    # Вопрос «кого предпочесть» решают стратегии — вернуть отсечённого здесь они
    # не вправе.
    #
    # nil — прошёл, Routing::Violation — нет. Причина из Reasons::SKIP (список
    # дословно совпадает с эталоном организаторов), объяснение содержит числа.
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
