# frozen_string_literal: true

require_relative 'base'
require_relative '../violation'
require_relative '../details'

module Routing
  module Constraints
    # Отсекает провайдера, у которого нет свободных реквизитов — карт, счетов
    # или терминалов, через которые уходят деньги.
    #
    # Проходит только строго положительное значение: nil — «данных нет»,
    # отрицательное — битый снапшот, оба отсеивают.
    #
    # По ходу очереди поле не расходуется (State::Providers его не меняет), но
    # читается из состояния так же, как в DailyLimit и InProgress — чтобы
    # источник данных у трёх проверок был один.
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
