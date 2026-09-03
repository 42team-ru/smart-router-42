# frozen_string_literal: true

module Routing
  # A-2: форматирует details для attempts с decision: "selected" — каждая
  # причина обязана содержать число (см. AGENTS.md, «причина без числа не
  # принимается»). Skip-причины форматируют сами constraints (details уже
  # часть Routing::Violation), сюда не входят.
  #
  # best_target_adherence сюда пока не входит: её числа — отклонение доли по
  # стратегии — появляются только вместе со стратегиями в Ф2/Ф3.
  module DetailsFormatter
    def self.only_eligible_provider(total_count)
      "1 допустимый провайдер из #{total_count}"
    end

    def self.first_eligible(candidates_count)
      "первый допустимый по приоритету из #{candidates_count} кандидатов в каскаде"
    end

    def self.next_in_cascade(previous_provider, previous_attempt_no, strategy)
      "#{previous_provider} отказал на попытке #{previous_attempt_no}, " \
        "следующий в каскаде по #{strategy}"
    end

    def self.fallback_no_eligible_provider(total_count)
      "допустимых внешних провайдеров 0 из #{total_count}"
    end
  end
end
