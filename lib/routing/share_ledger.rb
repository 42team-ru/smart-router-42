# frozen_string_literal: true

module Routing
  # Счётчики распределения только для текущего прогона очереди.
  # rubocop:disable-next Metrics/MethodLength
  class ShareLedger
    def initialize
      @count_by_name = Hash.new(0)
      @volume_by_name = Hash.new(0)
      @reservations = {}
    end

    def count_units(provider) = @count_by_name[provider_name(provider)]

    def volume_units(provider) = @volume_by_name[provider_name(provider)]

    def total_count_units = @count_by_name.values.sum

    def total_volume_units = @volume_by_name.values.sum

    def reserve(provider, operation)
      amount = valid_amount!(operation)
      name = provider_name(provider)
      key = reservation_key(name, operation)
      if @reservations.key?(key)
        raise ArgumentError,
              "reserve already held for (#{operation.operation_id}, #{name})"
      end

      @count_by_name[name] += 1
      @volume_by_name[name] += amount
      @reservations[key] = amount
      self
    end

    def commit(provider, operation)
      close_reservation!(provider, operation)
      self
    end

    def rollback(provider, operation)
      name = provider_name(provider)
      amount = close_reservation!(provider, operation)
      @count_by_name[name] -= 1
      @volume_by_name[name] -= amount
      if @count_by_name[name].negative? || @volume_by_name[name].negative?
        raise "negative share counters for #{name}"
      end

      self
    end

    def hold(provider, operation)
      reservation!(provider, operation)
      self
    end

    def open_reservations = @reservations.size

    private

    def provider_name(provider)
      provider.is_a?(String) ? provider : provider.name
    end

    def valid_amount!(operation)
      amount = operation.amount
      unless amount.is_a?(Integer) && amount.positive?
        raise ArgumentError,
              "operation amount must be a positive Integer, got #{amount.inspect}"
      end

      amount
    end

    def reservation_key(name, operation) = [operation.operation_id, name]

    def reservation!(provider, operation)
      name = provider_name(provider)
      @reservations.fetch(reservation_key(name, operation)) do
        raise ArgumentError, "no reserve held for (#{operation.operation_id}, #{name})"
      end
    end

    def close_reservation!(provider, operation)
      name = provider_name(provider)
      key = reservation_key(name, operation)
      reservation!(provider, operation)
      @reservations.delete(key)
    end
  end
end
