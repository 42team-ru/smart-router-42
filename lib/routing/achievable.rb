# frozen_string_literal: true

module Routing
  # Офлайн-расчёты: for_queue нельзя использовать при принятии онлайн-решения.
  # Расчёт содержит компактные целочисленные проходы по ограниченным данным очереди.
  # rubocop:disable-next Metrics/ModuleLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity, Style/ComparableClamp
  module Achievable
    module_function

    def renormalize(candidates)
      weights = candidates.to_h { |provider| [provider.name, weight_bp(provider)] }
      normalize_weights(weights)
    end

    def apportion(weights_bp, seats)
      return weights_bp.keys.sort.to_h { |name| [name, 0] } if seats.zero?
      if weights_bp.values.sum.zero?
        return allocate_largest_remainders(weights_bp.transform_values do
          1
        end, seats, weights_bp.size)
      end

      allocate_largest_remainders(weights_bp, seats, weights_bp.values.sum)
    end

    def for_queue(operations:, providers:, eligibility:)
      external = providers.reject { |provider| provider.name == 'spacepayments' }
      return {} if operations.empty?

      weights = external.to_h { |provider| [provider.name, weight_bp(provider)] }
      lower = lower_bounds(operations, weights.keys, eligibility)
      upper = upper_bounds(operations, external, eligibility)
      seats = apportion(weights, operations.size)
      clamp!(seats, lower, upper, weights, operations.size)
      bp = normalize_integer_seats(seats, operations.size)

      external.to_h do |provider|
        name = provider.name
        bound = if seats[name] == lower[name] && lower[name].positive?
                  :only_option
                elsif seats[name] == upper[name] && upper[name] < eligible_count(name, eligibility)
                  :money
                else
                  :none
                end
        [name,
         { target_bp: weights[name], achievable_seats: seats[name], achievable_bp: bp[name],
           bound: bound }]
      end
    end

    def normalize_weights(weights)
      return {} if weights.empty?

      total = weights.values.sum
      return equal_weights(weights.keys) if total.zero?

      allocate_largest_remainders(weights, 10_000, total)
    end

    def equal_weights(names)
      allocate_largest_remainders(names.to_h { |name| [name, 1] }, 10_000, names.size)
    end

    def allocate_largest_remainders(weights, scale, denominator)
      result = weights.to_h { |name, weight| [name, weight * scale / denominator] }
      remainder = scale - result.values.sum
      weights.keys.sort_by { |name| [-(weights[name] * scale % denominator), weights[name], name] }
             .first(remainder).each { |name| result[name] += 1 }
      result.sort_by { |name, value| [-value, name] }.to_h
    end

    def before?(left, right, weights, seats)
      left_weight = weights.fetch(left).to_i
      right_weight = weights.fetch(right).to_i
      left_value = left_weight * ((2 * seats.fetch(right)) + 1)
      right_value = right_weight * ((2 * seats.fetch(left)) + 1)
      return true if left_value > right_value
      return false if left_value < right_value
      return true if left_weight > right_weight
      return false if left_weight < right_weight

      left < right
    end

    def lower_bounds(operations, names, eligibility)
      names.to_h do |name|
        [name, operations.count do |operation|
          Array(eligibility[operation.operation_id]).sort == [name]
        end]
      end
    end

    def upper_bounds(operations, providers, eligibility)
      providers.to_h do |provider|
        eligible = operations.select do |operation|
          Array(eligibility[operation.operation_id]).include?(provider.name)
        end
        limit = provider.daily_amount_limit
        headroom = limit.nil? ? nil : limit - provider.daily_approved_amount.to_i
        count = if headroom.nil?
                  eligible.size
                else
                  eligible.map(&:amount).sort.reduce([0, 0]) do |(sum, count), amount|
                    sum + amount <= headroom ? [sum + amount, count + 1] : [sum, count]
                  end.last
                end
        [provider.name, count]
      end
    end

    def clamp!(seats, lower, upper, weights, total)
      seats.each_key { |name| seats[name] = [[seats[name], lower[name]].max, upper[name]].min }
      while seats.values.sum < total
        options = seats.keys.select { |name| seats[name] < upper[name] }
        break if options.empty?

        chosen = options.reduce { |best, name| before?(name, best, weights, seats) ? name : best }
        seats[chosen] += 1
      end
      while seats.values.sum > total
        options = seats.keys.select { |name| seats[name] > lower[name] }
        break if options.empty?

        chosen = options.reduce { |best, name| before?(best, name, weights, seats) ? name : best }
        seats[chosen] -= 1
      end
    end

    def normalize_integer_seats(seats, total) = allocate_largest_remainders(seats, 10_000, total)

    def eligible_count(name, eligibility)
      eligibility.values.count { |names| Array(names).include?(name) }
    end

    def weight_bp(provider) = provider.traffic_percentage.to_i * 100
  end
end
