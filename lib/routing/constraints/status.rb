# frozen_string_literal: true

require_relative 'base'
require_relative '../violation'
require_relative '../details'

module Routing
  module Constraints
    # Отсекает провайдера, который сейчас не принимает трафик.
    #
    # Самая первая и самая дешёвая проверка допуска: выключенному провайдеру
    # нельзя отдать заявку ни при каких лимитах и долях, поэтому спрашивать
    # что-то ещё бессмысленно.
    #
    # Работает так: статус обязан быть ровно "active". Любое другое значение —
    # отсев. Отдельно оговорён nil: отсутствие статуса означает «мы не знаем,
    # работает ли провайдер», а неизвестность трактуется не в его пользу —
    # молчаливо считать такого активным значило бы отправить деньги вслепую.
    class Status < Base
      REASON = 'provider_inactive'

      def self.violation(provider, _operation, _state)
        return nil if provider.status == 'active'

        status_label = provider.status.nil? ? 'nil' : provider.status
        Violation.new(reason: REASON, details: Details.inactive(status_label))
      end
    end
  end
end
