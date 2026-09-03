# frozen_string_literal: true

module State
  # Счётчики провайдеров. Резерв, а не пост-фактум: счётчики закрепляются
  # за провайдером в момент попадания в каскад.
  #
  #   исход      in_progress     daily_approved   бронь
  #   approved   освобождается   + amount         снимается
  #   rejected   освобождается   не трогаем       снимается
  #   expired    держится        не трогаем       снимается (для повтора)
  #
  # Незакрытый резерв тихо ломает eligibility на седьмой заявке.
  #
  # Domain::Provider иммутабельный (Data.define) — State держит параллельную
  # таблицу мутируемых полей по имени провайдера. Публичные читалки берут
  # значения только из этой таблицы, не из исходных объектов.
  class Providers
    # Единственный fallback: подхватывает операцию, у которой ни один внешний
    # провайдер не прошёл hard-constraints. Отсутствие в снапшоте — фатально.
    FALLBACK_NAME = 'spacepayments'

    # Поля, которые State мутирует. Всё остальное живёт в исходном Provider
    # и берётся оттуда через #fetch_provider(name).
    MUTABLE_FIELDS = %i[in_progress_count in_progress_amount
                        daily_approved_amount available_requisites].freeze

    def initialize(providers)
      validate_no_duplicates!(providers)
      validate_fallback_present!(providers)

      @providers_by_name = providers.to_h { |p| [p.name, p] }
      @state_by_name = providers.to_h do |p|
        [p.name, MUTABLE_FIELDS.to_h { |f| [f, p.public_send(f).to_i] }]
      end
      @reservations = {}
    end

    def reserve(provider, operation)
      name = provider.name
      key = [operation.operation_id, name]
      if @reservations.key?(key)
        raise ArgumentError,
              "reserve already held for (#{key.first}, #{name})"
      end

      @state_by_name[name][:in_progress_count] += 1
      @state_by_name[name][:in_progress_amount] += operation.amount
      @reservations[key] = operation.amount
    end

    def commit(provider, operation)
      name = provider.name
      @state_by_name[name][:daily_approved_amount] += operation.amount
      release_capacity(name, operation)
      @reservations.delete([operation.operation_id, name])
    end

    def rollback(provider, operation)
      name = provider.name
      release_capacity(name, operation)
      @reservations.delete([operation.operation_id, name])
    end

    # expired: резерв держится (§4 ARCH), счётчики in_progress НЕ откатываются.
    # Запись в @reservations снимаем — Ф2 PendingResolver может обработать ту
    # же операцию повторно, и вторая reserve не должна упасть на идемпотентности.
    def hold(provider, operation)
      @reservations.delete([operation.operation_id, provider.name])
    end

    def in_progress_count(name)
      fetch_state(name).fetch(:in_progress_count)
    end

    def in_progress_amount(name)
      fetch_state(name).fetch(:in_progress_amount)
    end

    def daily_approved_amount(name)
      fetch_state(name).fetch(:daily_approved_amount)
    end

    def available_requisites(name)
      fetch_state(name).fetch(:available_requisites)
    end

    def snapshot(name)
      fetch_state(name).dup
    end

    def fallback
      @providers_by_name.fetch(FALLBACK_NAME)
    end

    private

    def release_capacity(name, operation)
      @state_by_name[name][:in_progress_count] -= 1
      @state_by_name[name][:in_progress_amount] -= operation.amount
    end

    def fetch_state(name)
      @state_by_name.fetch(name) { raise ArgumentError, "unknown provider #{name}" }
    end

    def validate_no_duplicates!(providers)
      names = providers.map(&:name)
      return if names.uniq.length == names.length

      raise ArgumentError, "providers contain duplicates by name: #{names - names.uniq}"
    end

    def validate_fallback_present!(providers)
      return if providers.any? { |p| p.name == FALLBACK_NAME }

      raise ArgumentError, "fallback provider #{FALLBACK_NAME} missing from snapshot"
    end
  end
end
