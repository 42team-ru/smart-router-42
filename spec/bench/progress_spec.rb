# frozen_string_literal: true

require 'stringio'
require 'bench/progress'

# Прогресс обязан быть дешёвым и не врать. Дешёвым — потому что tick вызывается
# на КАЖДОЙ операции, а их бывает миллион; не врать — потому что «осталось ~»
# читают как обещание.
#
# Часы здесь подставные: спек про поведение, а не про то, как быстро бежит
# машина, и от реального времени зависеть не должен.
# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations -- каждый
# пример готовит подставные часы и проверяет строку набором связанных
# утверждений: «есть доля» без «нет остатка» доказывает половину.
RSpec.describe Bench::Progress do
  let(:io) { StringIO.new }

  # Часы возвращают заранее заданную последовательность отметок.
  def clock_from(marks)
    queue = marks.dup
    -> { queue.size > 1 ? queue.shift : queue.first }
  end

  def progress(marks, total: nil)
    described_class.new(io: io, total: total, clock: clock_from(marks))
  end

  describe Bench::Progress::Null do
    it 'молчит на все вызовы и ничего не требует' do
      null = described_class.new

      expect do
        null.stage('что-то')
        null.tick(1)
        null.finish_stage
      end.not_to raise_error
    end
  end

  it 'объявляет этап и закрывает предыдущий с его временем' do
    reporter = progress([0.0, 3.5, 3.5])

    reporter.stage('первый')
    reporter.stage('второй')

    expect(io.string).to include('[1] первый...', '[1] первый: готово за 3.5 с', '[2] второй...')
  end

  it 'переводит длинные этапы в минуты и секунды' do
    reporter = progress([0.0, 154.0])

    reporter.stage('долгий')
    reporter.finish_stage

    expect(io.string).to include('готово за 2 м 34 с')
  end

  # Главное свойство: tick на «неровной» операции обязан выйти по одному
  # сравнению целых, не трогая часы. Если он полезет за временем — фейковые
  # часы кончатся, а тут это просто проверяется по молчанию вывода.
  it 'не печатает ничего между контрольными точками' do
    reporter = progress([0.0], total: 1_000_000)
    reporter.stage('прогон')
    io.truncate(io.rewind)

    (1..4095).each { |seen| reporter.tick(seen) }

    expect(io.string).to be_empty
  end

  it 'печатает долю, скорость и остаток на контрольной точке' do
    reporter = progress([0.0, 4.0], total: 100_000)
    reporter.stage('прогон')
    io.truncate(io.rewind)

    reporter.tick(4096)

    expect(io.string).to include('4 096 из 100 000 (4%)', '1 024 оп/с', 'осталось ~1 м 34 с')
  end

  it 'молчит на контрольной точке, если с прошлой строки прошло меньше интервала' do
    reporter = progress([0.0, 0.5], total: 100_000)
    reporter.stage('прогон')
    io.truncate(io.rewind)

    reporter.tick(4096)

    expect(io.string).to be_empty
  end

  it 'без известного total не выдумывает ни долю, ни остаток' do
    reporter = progress([0.0, 4.0])
    reporter.stage('прогон')
    io.truncate(io.rewind)

    reporter.tick(4096)

    expect(io.string).to include('4 096')
    expect(io.string).not_to include('%')
    expect(io.string).not_to include('осталось')
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
