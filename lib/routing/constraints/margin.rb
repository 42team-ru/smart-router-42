# frozen_string_literal: true

require_relative 'base'
require_relative '../violation'
require_relative '../details'

module Routing
  module Constraints
    # Отсекает провайдера, работа с которым уводит сделку в убыток.
    #
    # Провайдер берёт свой процент, мерчант закладывает свой. Если процент
    # провайдера выше — каждая проведённая через него выплата приносит убыток,
    # и такого провайдера в каскад пускать нельзя. Исключение делает флаг
    # allow_negative_agreement: иногда убыточный канал держат сознательно,
    # ради оборота или доступности направления. Флаг обязан быть явным —
    # молчаливого «наверное, так и задумано» здесь нет.
    #
    # Проценты сравниваются через Rational, а не Float, и это не педантизм:
    # в JSON значения десятичные, а двоичный Float не представляет их точно.
    # Сравнение 1.2 и 1.5 во Float даст верный ответ, а вот равные по смыслу
    # значения могут разойтись на последнем бите — и провайдер то проходит, то
    # нет от прогона к прогону. Побайтовая воспроизводимость этого не прощает.
    class Margin < Base
      REASON = 'negative_margin'

      def self.violation(provider, _operation, _state)
        provider_margin = provider.provider_margin_pct
        merchant_margin = provider.merchant_margin_pct
        return nil if provider_margin.nil? || merchant_margin.nil?
        return nil if provider.allow_negative_agreement
        return nil unless Rational(provider_margin.to_s) > Rational(merchant_margin.to_s)

        Violation.new(
          reason: REASON,
          details: Details.negative_margin(provider_margin, merchant_margin)
        )
      end
    end
  end
end
