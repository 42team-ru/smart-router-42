# frozen_string_literal: true

require_relative '../routing/share_ledger'

module State
  # Счётчики провайдеров. Резерв, а не пост-фактум: счётчики закрепляются
  # за провайдером в момент попадания в каскад.
  #
  #   исход      in_progress     daily_approved   бронь State           доля (ShareLedger)
  #   approved   освобождается   + amount         снимается             commit
  #   rejected   освобождается   не трогаем       снимается             rollback
  #   expired    держится        не трогаем       @held_reservations    hold
  #
  # Незакрытый резерв тихо ломает eligibility на седьмой заявке.
  # expired-резерв закрывает Execution::PendingResolver через #resolve_hold.
  #
  # П2 (docs/plans/P6/P2_rate_limit.md): счётчик запросов в минуту
  # (@minute_requests) растёт только в #reserve — по факту отправки запроса
  # провайдеру, включая fallback-резерв. Единственное сознательное отступление
  # от таблицы исходов выше: счётчик НЕ уменьшается ни в #rollback, ни в
  # #hold, ни в #commit — интенсивность считает отправленные запросы, а не
  # занятую ёмкость, поэтому отказ или таймаут не возвращают лимит.
  #
  # Domain::Provider иммутабельный (Data.define) — State держит параллельную
  # таблицу мутируемых полей по имени провайдера. Публичные читалки берут
  # значения только из этой таблицы, не из исходных объектов.
  #
  # Доли текущего прогона очереди инкапсулированы в @shares (Routing::ShareLedger).
  # State делегирует ему ShareCounters-роль (count_units/volume_units/total_*/
  # open_reservations) и первой строкой каждой мутации проксирует reserve/
  # commit/rollback/hold в леджер. Стратегии видят State как ShareCounters.
  # rubocop:disable Metrics/ClassLength -- один связный ответственник:
  # in_progress + daily_approved + бронь + делегат к ShareLedger. Разрезание
  # только увеличит связность через новый класс.
  class Providers
    FALLBACK_NAME = 'spacepayments'

    MUTABLE_FIELDS = %i[in_progress_count in_progress_amount
                        daily_approved_amount available_requisites].freeze

    ALLOWED_RESOLUTIONS = %i[approved rejected].freeze

    attr_reader :shares

    def initialize(providers)
      validate_no_duplicates!(providers)
      validate_fallback_present!(providers)

      @providers_by_name = providers.to_h { |p| [p.name, p] }
      @state_by_name = providers.to_h do |p|
        [p.name, MUTABLE_FIELDS.to_h { |f| [f, p.public_send(f).to_i] }]
      end
      @reservations = {}
      @held_reservations = {}
      @shares = Routing::ShareLedger.new
      @minute_requests = Hash.new(0)
    end

    def reserve(provider, operation)
      @shares.reserve(provider, operation)
      name = provider_name(provider)
      key = [operation.operation_id, name]
      ensure_slot_free!(key, name)
      @state_by_name[name][:in_progress_count] += 1
      @state_by_name[name][:in_progress_amount] += operation.amount
      @reservations[key] = operation.amount
      increment_minute_counter(name, operation)
      self
    end

    # Сколько запросов уже отправлено провайдеру в минуту. minute — строка
    # вида "2026-07-30T09:05" (operation.created_at[0, 16]), её считает вызывающая
    # сторона (Routing::Constraints::RateLimit.minute_key), а не системные часы --
    # см. правило проекта про запрет Time.now в lib/routing.
    def requests_in_minute(name, minute)
      @minute_requests[[name, minute]]
    end

    def commit(provider, operation)
      @shares.commit(provider, operation)
      name = provider_name(provider)
      @state_by_name[name][:daily_approved_amount] += operation.amount
      release_capacity(name, operation)
      @reservations.delete([operation.operation_id, name])
      self
    end

    def rollback(provider, operation)
      @shares.rollback(provider, operation)
      name = provider_name(provider)
      release_capacity(name, operation)
      @reservations.delete([operation.operation_id, name])
      self
    end

    def hold(provider, operation)
      @shares.hold(provider, operation)
      name = provider_name(provider)
      key = [operation.operation_id, name]
      amount = @reservations.delete(key)
      @held_reservations[key] = amount if amount
      self
    end

    # Закрывает expired-резерв, поставленный #hold. Actual — что на самом деле
    # ответил провайдер по статус-чеку: :approved или :rejected. Прошлые
    # решения не пересчитываются (§7 ARCH): only вносится delta по (op, provider).
    def resolve_hold(provider, operation, actual)
      validate_actual!(actual)
      name = provider_name(provider)
      key = [operation.operation_id, name]
      amount = @held_reservations.delete(key) ||
               (raise ArgumentError,
                      "no held reservation for (#{operation.operation_id}, #{name})")

      release_held(name, amount)
      apply_resolution(provider, operation, name, actual)
      self
    end

    def count_units(provider) = @shares.count_units(provider)
    def volume_units(provider) = @shares.volume_units(provider)
    def total_count_units = @shares.total_count_units
    def total_volume_units = @shares.total_volume_units
    def open_reservations = @shares.open_reservations

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

    def provider_name(provider)
      provider.is_a?(String) ? provider : provider.name
    end

    def ensure_slot_free!(key, name)
      return unless @reservations.key?(key)

      raise ArgumentError, "reserve already held for (#{key.first}, #{name})"
    end

    def increment_minute_counter(name, operation)
      minute = operation.created_at[0, 16]
      @minute_requests[[name, minute]] += 1
    end

    def release_capacity(name, operation)
      @state_by_name[name][:in_progress_count] -= 1
      @state_by_name[name][:in_progress_amount] -= operation.amount
    end

    def release_held(name, amount)
      @state_by_name[name][:in_progress_count] -= 1
      @state_by_name[name][:in_progress_amount] -= amount
    end

    def apply_resolution(provider, operation, name, actual)
      case actual
      when :approved
        @state_by_name[name][:daily_approved_amount] += operation.amount
        @shares.commit(provider, operation)
      when :rejected
        @shares.rollback(provider, operation)
      end
    end

    def validate_actual!(actual)
      return if ALLOWED_RESOLUTIONS.include?(actual)

      raise ArgumentError,
            "actual must be :approved or :rejected, got #{actual.inspect}"
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
  # rubocop:enable Metrics/ClassLength
end
