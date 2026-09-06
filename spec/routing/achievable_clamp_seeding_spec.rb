# frozen_string_literal: true

require 'routing/achievable'

# Achievable#clamp! раздаёт и срезает единицы по одной. Это верно, но для
# for_volume единица — рубль, а total — сумма всей очереди: на синтетической
# очереди в 501 заявку нижний цикл делал 7 694 870 итераций и стоил ~10 с из
# 19 с прогона bin/route.
#
# Теперь заведомая часть цикла перепрыгивается двоичным поиском порога, а
# прежние циклы добирают остаток. Оптимизация обязана быть НЕОТЛИЧИМОЙ от
# перебора по единице — иначе достижимые доли в отчёте поедут, и поедут молча.
#
# Поэтому здесь лежит наивная реализация (буквально прежний код) и сравнение с
# боевой на случайных входах. Веса нарочно берутся с нулями и повторами: при
# w = 0 ключ w/(2s+1) вырождается в ноль при любом s, а при равных весах
# возникают ничьи — оба случая порогом не выражаются и разбираются отдельными
# проходами, значит именно там ошибка и спряталась бы.
#
# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
# rubocop:disable Metrics/PerceivedComplexity, Style/ComparableClamp -- naive_clamp!
# обязан быть КОПИЕЙ прежнего кода слово в слово: причесать его значит
# перестать сравнивать с тем, что было.
# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations -- один прогон
# проверяется набором связанных утверждений.
RSpec.describe 'Routing::Achievable#clamp! — засев порогом' do
  # Прежний clamp! слово в слово: только шаг в единицу, без засева.
  def naive_clamp!(seats, lower, upper, weights, total)
    seats.each_key { |name| seats[name] = [[seats[name], lower[name]].max, upper[name]].min }
    while seats.values.sum < total
      options = seats.keys.select { |name| seats[name] < upper[name] }
      break if options.empty?

      chosen = options.reduce do |best, name|
        Routing::Achievable.before?(name, best, weights, seats) ? name : best
      end
      seats[chosen] += 1
    end
    while seats.values.sum > total
      options = seats.keys.select { |name| seats[name] > lower[name] }
      break if options.empty?

      chosen = options.reduce do |best, name|
        Routing::Achievable.before?(best, name, weights, seats) ? name : best
      end
      seats[chosen] -= 1
    end
    seats
  end

  # Детерминированный генератор: спек обязан падать на одном и том же входе, а
  # не «иногда». Диапазоны маленькие — наивная реализация линейна по total, и
  # на миллионах она бы считалась минутами.
  def random_case(random)
    names = (0...random.rand(1..5)).map { |index| "p#{index}" }
    weights = names.to_h { |name| [name, [0, 0, 100, 100, 2500, 5000].sample(random: random)] }
    lower = names.to_h { |name| [name, random.rand(0..3) * random.rand(0..40)] }
    upper = names.to_h { |name| [name, lower[name] + random.rand(0..600)] }
    base = names.to_h { |name| [name, random.rand(0..700)] }
    { weights: weights, lower: lower, upper: upper, base: base,
      total: random.rand(0..(upper.values.sum + 60)) }
  end

  it 'даёт ровно тот же результат, что перебор по единице, на 400 случайных входах' do
    random = Random.new(20_260_906)
    mismatches = Array.new(400) { random_case(random) }.reject do |input|
      fast = input[:base].dup
      slow = input[:base].dup
      Routing::Achievable.clamp!(fast, input[:lower], input[:upper], input[:weights],
                                 input[:total])
      naive_clamp!(slow, input[:lower], input[:upper], input[:weights], input[:total])
      fast == slow
    end

    expect(mismatches).to eq([])
  end

  # Отдельно и явно: ради этого всё и делалось. Наивная реализация линейна по
  # total, поэтому на сумме в десятки миллионов «рублей» она не уложилась бы ни
  # в какой разумный срок, а засев обязан отвечать мгновенно.
  it 'срезает миллионы единиц без перебора по единице' do
    names = %w[alfa beta gamma]
    weights = { 'alfa' => 5000, 'beta' => 3000, 'gamma' => 2000 }
    lower = names.to_h { |name| [name, 0] }
    upper = names.to_h { |name| [name, 40_000_000] }
    seats = names.to_h { |name| [name, 40_000_000] }

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Routing::Achievable.clamp!(seats, lower, upper, weights, 1_000_000)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    expect(seats.values.sum).to eq(1_000_000)
    expect(elapsed).to be < 1.0
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
# rubocop:enable Metrics/PerceivedComplexity, Style/ComparableClamp
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
