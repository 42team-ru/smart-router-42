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

    # Достижимая доля по ОБЪЁМУ (рубли), а не по количеству мест — родная
    # сестра for_queue. Механика та же (apportion по largest remainders +
    # clamp! до [lower; upper] + перенормировка в базисные пункты), только
    # единица распределения — сумма операции, а не штука.
    #
    # Приближение, а не точный расчёт: achievability по объёму в общем случае
    # — задача о рюкзаке (какое подмножество операций даст провайдеру ровно
    # столько денег, сколько нужно), и точного решения в один проход у неё
    # нет. Нижняя граница точна (сумма singleton-операций считается без
    # допущений), а верхняя — оценка сверху: min(сумма всех допустимых
    # операций, свободный дневной лимит). В отличие от for_queue, где
    # headroom подбирает поднабор операций жадно по возрастанию суммы (это
    # штуки, их нельзя дробить), деньги внутри лимита не обязаны совпадать с
    # суммой каких-то конкретных заявок — поэтому кэп по деньгам это прямой
    # минимум, а не пересчёт по операциям. Как и офлайн-эталон называет своё
    # число offline_bound, а не offline_optimum, здесь оценка сверху, а не
    # доказанный максимум.
    def for_volume(operations:, providers:, eligibility:)
      external = providers.reject { |provider| provider.name == 'spacepayments' }
      return {} if operations.empty?

      total = operations.sum(&:amount)
      weights = external.to_h { |provider| [provider.name, volume_weight_bp(provider)] }
      return zero_volume_result(external, weights) if total.zero?

      lower = lower_volume_bounds(operations, weights.keys, eligibility)
      upper = upper_volume_bounds(operations, external, eligibility)
      seats = apportion(weights, total)
      clamp!(seats, lower, upper, weights, total)
      bp = normalize_integer_seats(seats, total)

      external.to_h do |provider|
        name = provider.name
        eligible_amount = eligible_volume(name, eligibility, operations)
        bound = if seats[name] == lower[name] && lower[name].positive?
                  :only_option
                elsif seats[name] == upper[name] && upper[name] < eligible_amount
                  :money
                else
                  :none
                end
        [name,
         { target_bp: weights[name], achievable_amount: seats[name], achievable_bp: bp[name],
           bound: bound }]
      end
    end

    # Сумма операций в очереди равна нулю (все нулевые чеки) — распределять
    # физически нечего, но это не пустая очередь, поэтому for_queue-подобный
    # ранний return {} тут не подходит: внешние провайдеры обязаны остаться в
    # результате с нулевой достижимой долей, а не пропасть из отчёта.
    def zero_volume_result(external, weights)
      external.to_h do |provider|
        name = provider.name
        [name, { target_bp: weights[name], achievable_amount: 0, achievable_bp: 0, bound: :none }]
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

    def lower_volume_bounds(operations, names, eligibility)
      names.to_h do |name|
        [name, operations.sum do |operation|
          Array(eligibility[operation.operation_id]).sort == [name] ? operation.amount : 0
        end]
      end
    end

    # Кэп по деньгам — минимум суммы допустимых операций и свободного
    # headroom, но не меньше нуля: провайдер, уже выбравший весь лимит (или
    # ушедший в минус по снапшоту), не может получить отрицательную
    # достижимую долю. nil в daily_amount_limit — «ограничения нет», а не
    # ноль, поэтому в этом случае кэпа по деньгам вообще нет.
    def upper_volume_bounds(operations, providers, eligibility)
      providers.to_h do |provider|
        eligible_amount = eligible_volume(provider.name, eligibility, operations)
        limit = provider.daily_amount_limit
        headroom = limit.nil? ? nil : limit - provider.daily_approved_amount.to_i
        amount = headroom.nil? ? eligible_amount : [eligible_amount, [headroom, 0].max].min
        [provider.name, amount]
      end
    end

    def eligible_volume(name, eligibility, operations)
      operations.sum do |operation|
        Array(eligibility[operation.operation_id]).include?(name) ? operation.amount : 0
      end
    end

    # volume_share_pct отсутствует в снапшоте организаторов -- тот же
    # фоллбэк на traffic_percentage, что и Routing::Strategies::VolumeShare
    # и Reporting::Distributions.target_of.
    def volume_weight_bp(provider)
      (provider.volume_share_pct || provider.traffic_percentage).to_i * 100
    end

    # Досыпка и срезка идут по одной единице. Для for_queue единица — операция,
    # и цикл крутится по числу заявок. Для for_volume единица — РУБЛЬ, а total —
    # сумма всей очереди, поэтому цена та же формально, но другая практически:
    # на синтетической очереди в 501 заявку нижний цикл делал 7 694 870
    # итераций и стоил ~10 с из 19 с всего прогона bin/route; даже на публичной
    # очереди из 10 заявок он проходил 11 200 раз.
    #
    # Порядок раздачи и срезки задаёт ключ w/(2s+1) — тот же метод делителей,
    # что и в count_share: вверх единицы уходят по убыванию ключа, вниз — по
    # возрастанию. Значит итог — это «все единицы по одну сторону порога», и
    # порог ищется двоичным поиском вместо перебора по единице.
    #
    # Засев не меняет поведение, а лишь перепрыгивает заведомую часть цикла:
    # при w > 0 ключ инъективен по s, поэтому ровно на пороге у провайдера
    # лежит не больше одной единицы, и остаток после засева не длиннее числа
    # провайдеров — его добирают прежние циклы, слово в слово те же.
    # Исключение — нулевой вес: там ключ равен нулю при любом s, такие
    # провайдеры всегда крайние в порядке и разбираются отдельным проходом.
    def clamp!(seats, lower, upper, weights, total)
      seats.each_key { |name| seats[name] = [[seats[name], lower[name]].max, upper[name]].min }
      seed_up!(seats, upper, weights, total)
      while seats.values.sum < total
        options = seats.keys.select { |name| seats[name] < upper[name] }
        break if options.empty?

        chosen = options.reduce { |best, name| before?(name, best, weights, seats) ? name : best }
        seats[chosen] += 1
      end
      seed_down!(seats, lower, weights, total)
      while seats.values.sum > total
        options = seats.keys.select { |name| seats[name] > lower[name] }
        break if options.empty?

        chosen = options.reduce { |best, name| before?(best, name, weights, seats) ? name : best }
        seats[chosen] -= 1
      end
    end

    # Знаменатель порога: двоичный поиск идёт по целому числителю при
    # фиксированном знаменателе, без Rational и без float. 2^128 с запасом
    # разделяет соседние ключи w/(2s+1) — они расходятся не ближе чем на
    # w/(2s²), а s ограничено суммой очереди.
    SEED_DENOMINATOR = 1 << 128

    # Сколько единиц у провайдера имеют ключ строго выше порога p/q:
    # w/(2s+1) > p/q ⟺ s < (w·q − p)/(2p).
    def units_above(weight, numerator)
      return 0 unless weight.positive? && numerator.positive?

      span = (weight * SEED_DENOMINATOR) - numerator
      return 0 if span <= 0

      ((span + (2 * numerator) - 1) / (2 * numerator))
    end

    # На сколько единиц садится провайдер, если срезать всё с ключом строго
    # ниже порога. Срезка идёт сверху вниз и останавливается на первом s, где
    # ключ дотянул до порога: w/(2s+1) ≥ p/q ⟺ s ≤ (w·q − p)/(2p).
    # Вызывается только при numerator > 0.
    def survivors_above(weight, numerator)
      return 0 unless weight.positive?

      ((weight * SEED_DENOMINATOR) - numerator) / (2 * numerator)
    end

    # Двоичный поиск числителя порога: predicate монотонен по нему, ищется
    # граница. Шагов хватает с запасом — знаменатель 2^128, а различить надо
    # соседние ключи вида w/(2s+1).
    def seed_threshold(top, &predicate)
      low = 0
      high = top
      260.times do
        break if high - low <= 1

        mid = (low + high) / 2
        predicate.call(mid) ? high = mid : low = mid
      end
      high
    end

    # Верхняя граница поиска: при таком числителе выше порога не остаётся ни
    # одной единицы ни у кого, то есть предикат заведомо на своей стороне.
    def threshold_top(weights, names)
      (weights.values_at(*names).map(&:to_i).max * SEED_DENOMINATOR * 2) + 1
    end

    def positive_weight_names(seats, weights)
      seats.keys.select { |name| weights[name].to_i.positive? }
    end

    # Провайдеры с нулевым весом: ключ у них равен нулю при любом s, поэтому
    # вверх они идут строго последними (по возрастанию имени), вниз — строго
    # первыми (по убыванию имени). Инъективности ключа тут нет, и порог их не
    # выражает, значит считаются они отдельным проходом.
    def zero_weight_names(seats, weights)
      seats.keys.select { |name| weights[name].to_i.zero? }
    end

    def seed_up!(seats, upper, weights, total)
      return if total - seats.values.sum <= 0

      seed_positive_up!(seats, upper, weights, total)
      # Нулевой вес получает единицы только после того, как все положительные
      # упёрлись в свой потолок: ключ 0 проигрывает любому положительному, и
      # раздать нулевому раньше — значит опередить настоящий порядок.
      return if positive_weight_names(seats, weights).any? { |name| seats[name] < upper[name] }

      fill_zero_weight_up!(seats, upper, weights, total - seats.values.sum)
    end

    def seed_positive_up!(seats, upper, weights, total)
      names = positive_weight_names(seats, weights)
      return if names.empty?

      constant = seats.values.sum - names.sum { |name| seats[name] }
      numerator = seed_threshold(threshold_top(weights, names)) do |candidate|
        constant + names.sum { |name| up_seats(seats, upper, weights, name, candidate) } <= total
      end
      names.each { |name| seats[name] = up_seats(seats, upper, weights, name, numerator) }
    end

    def up_seats(seats, upper, weights, name, numerator)
      taken = units_above(weights[name].to_i, numerator)
      [[taken, seats[name]].max, upper[name]].min
    end

    def fill_zero_weight_up!(seats, upper, weights, gap)
      return if gap <= 0

      zero_weight_names(seats, weights).sort.each do |name|
        take = [upper[name] - seats[name], gap].min
        next unless take.positive?

        seats[name] += take
        gap -= take
        break if gap.zero?
      end
    end

    def seed_down!(seats, lower, weights, total)
      gap = seats.values.sum - total
      return if gap <= 0

      gap = drain_zero_weight_down!(seats, lower, weights, gap)
      seed_positive_down!(seats, lower, weights, total) if gap.positive?
    end

    def seed_positive_down!(seats, lower, weights, total)
      names = positive_weight_names(seats, weights)
      return if names.empty?

      constant = seats.values.sum - names.sum { |name| seats[name] }
      numerator = seed_threshold(threshold_top(weights, names)) do |candidate|
        constant + names.sum { |name| down_seats(seats, lower, weights, name, candidate) } < total
      end
      kept = [numerator - 1, 0].max
      names.each { |name| seats[name] = down_seats(seats, lower, weights, name, kept) }
    end

    def down_seats(seats, lower, weights, name, numerator)
      return seats[name] unless numerator.positive?

      survivors = survivors_above(weights[name].to_i, numerator)
      [[survivors, lower[name]].max, seats[name]].min
    end

    def drain_zero_weight_down!(seats, lower, weights, gap)
      zero_weight_names(seats, weights).sort.reverse_each do |name|
        take = [seats[name] - lower[name], gap].min
        next unless take.positive?

        seats[name] -= take
        gap -= take
        break if gap.zero?
      end
      gap
    end

    def normalize_integer_seats(seats, total) = allocate_largest_remainders(seats, 10_000, total)

    def eligible_count(name, eligibility)
      eligibility.values.count { |names| Array(names).include?(name) }
    end

    def weight_bp(provider) = provider.traffic_percentage.to_i * 100
  end
end
