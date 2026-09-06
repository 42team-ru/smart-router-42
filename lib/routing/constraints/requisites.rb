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
    # чем мы успеваем его исчерпать (см. State::Providers#available_requisites,
    # ни одна мутация состояния это поле не трогает).
    #
    # Тем не менее читаем его так же, как DailyLimit и InProgress: если
    # передано состояние прогона, значение берётся из него, а не из снимка
    # провайдера, — чтобы источник данных был единым для всех троих проверок,
    # а не потому, что это поле меняется по ходу очереди сегодня. Без
    # состояния (офлайн-расчёт, Routing::Achievable, Reporting) считается по
    # снимку, как раньше.
    class Requisites < Base
      REASON = 'no_requisites'

      def self.violation(provider, _operation, state)
        requisites = live_requisites(provider, state)
        return nil if requisites&.positive?

        Violation.new(reason: REASON,
                      details: Details.no_requisites(requisites.nil? ? 0 : requisites))
      end

      def self.live_requisites(provider, state)
        return state.available_requisites(provider.name) if state.respond_to?(:available_requisites)

        provider.available_requisites
      end

      private_class_method :live_requisites
    end
  end
end
