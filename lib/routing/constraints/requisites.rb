# frozen_string_literal: true

require_relative 'base'
require_relative '../violation'
require_relative '../details'

module Routing
  module Constraints
    # Отсекает провайдера, которому физически нечем провести выплату.
    #
    # Реквизиты — это карты, счета или терминалы, через которые провайдер
    # отправляет деньги. Свободных нет — заявку исполнить нечем, сколько бы
    # лимитов ни оставалось.
    #
    # Проходит только строго положительное значение. Ноль — очевидный отсев,
    # nil трактуется как «данных нет» и допуска не даёт, отрицательное значение
    # тоже отсеивает: такого быть не должно, но если снапшот пришёл битым,
    # правильнее не отдать заявку, чем сделать вид, что реквизиты есть.
    #
    # Реквизиты — единственный ресурс провайдера, который в текущей модели не
    # расходуется по ходу очереди: считается, что канал освобождается быстрее,
    # чем мы успеваем его исчерпать (см. State::Providers#available_requisites).
    class Requisites < Base
      REASON = 'no_requisites'

      def self.violation(provider, _operation, _state)
        requisites = provider.available_requisites
        return nil if requisites&.positive?

        Violation.new(reason: REASON,
                      details: Details.no_requisites(requisites.nil? ? 0 : requisites))
      end
    end
  end
end
