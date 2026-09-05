# frozen_string_literal: true

module Synthetic
  # Общий словарь банков для генератора. Маркерные банки — механизм
  # конструктивного оракула: bank_marker_<i> входит в banks ровно одного
  # провайдера, поэтому операция с этим банком проходит Routing::Constraints::BankFilter
  # только у одного кандидата — ответ известен заранее, без запуска роутера.
  # bank_orphan не входит ни в чей список — гарантированный fallback.
  module Banks
    COMMON = %w[sberbank tinkoff alfa vtb gazprombank raiffeisen otkritie sovcombank].freeze
    ORPHAN = 'bank_orphan'

    module_function

    def marker(index) = "bank_marker_#{index}"

    # Детерминированное (без Random) подмножество общего пула для wide-провайдера:
    # узкие профили дают 2 банка, остальные — весь пул. rotate вместо sample —
    # разброс без источника случайности.
    def pool_for(index, size) = COMMON.rotate(index).first(size)
  end
end
