# frozen_string_literal: true

module Routing
  # Элемент массива attempts в отчёте.
  #
  # decision принимает только "selected" и "skipped" — валидатор организаторов
  # считает любое другое значение ошибкой структуры. Неудачная попытка
  # кодируется как decision: "selected" + result: "rejected", а не третьим
  # значением decision.
  Attempt = Data.define(:provider, :decision, :reason, :details, :strategy,
                        :attempt_no, :result) do
    # rubocop:disable Metrics/ParameterLists -- поля attempts зафиксированы форматом отчёта
    def initialize(provider:, decision:, reason:, details: nil, strategy: nil,
                   attempt_no: nil, result: nil)
      # rubocop:enable Metrics/ParameterLists
      unless self.class::ALLOWED_DECISIONS.include?(decision)
        raise ArgumentError, "decision must be 'selected' or 'skipped', got #{decision.inspect}"
      end

      super
    end

    # Хеш с фиксированным порядком ключей. nil-поля выбрасываются, кроме
    # provider, decision, reason — они присутствуют всегда.
    def to_h
      self.class::KEY_ORDER.each_with_object({}) do |key, hash|
        value = public_send(key)
        next if value.nil? && !self.class::ALWAYS_PRESENT.include?(key)

        hash[key] = value
      end
    end
  end

  # Константы вынесены за пределы блока Data.define, чтобы не определять их
  # внутри блока (грепом на это ловит Lint/ConstantDefinitionInBlock).
  class Attempt
    # Единственные допустимые значения decision.
    ALLOWED_DECISIONS = %w[selected skipped].freeze

    # Фиксированный порядок ключей в отчёте. Менять нельзя — формат заморожен.
    KEY_ORDER = %i[provider decision reason details strategy attempt_no result].freeze

    # Поля, которые присутствуют в to_h всегда, даже если их значение nil.
    ALWAYS_PRESENT = %i[provider decision reason].freeze
  end
end
