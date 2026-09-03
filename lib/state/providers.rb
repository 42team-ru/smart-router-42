# frozen_string_literal: true

module State
  # Счётчики провайдеров. Резерв, а не пост-фактум:
  # счётчики закрепляются за провайдером в момент попадания в каскад.
  #
  #   исход      in_progress     daily_approved   счётчик доли
  #   approved   освобождается   + amount         остаётся у провайдера
  #   rejected   освобождается   не трогаем       возвращается
  #   expired    держится        не трогаем       остаётся
  #
  # Незакрытый резерв тихо ломает eligibility на седьмой заявке.
  class Providers
    def reserve(provider, operation)
      raise NotImplementedError, "#{self.class}#reserve"
    end

    def commit(provider, operation)
      raise NotImplementedError, "#{self.class}#commit"
    end

    def rollback(provider, operation)
      raise NotImplementedError, "#{self.class}#rollback"
    end

    def hold(provider, operation)
      raise NotImplementedError, "#{self.class}#hold"
    end
  end
end
