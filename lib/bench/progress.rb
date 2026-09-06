# frozen_string_literal: true

require_relative 'measurement'

module Bench
  # Ход выполнения на STDERR: где мы сейчас и сколько осталось.
  #
  # Зачем отдельным объектом, а не puts прямо в Runner: прогресс — это способ
  # смотреть, а не считать. Runner про формат и поток вывода знать не должен, а
  # выключенный прогресс обязан стоить ровно ничего (см. Progress::Null).
  #
  # Почему STDERR: STDOUT несёт отчёт, который читают и глазами, и grep'ом.
  # Мешать в него строки хода — значит ломать оба сценария. `2>&1 | tee` ловит
  # обе струи, поэтому в файл попадает всё.
  #
  # Стоимость на операцию — одно сравнение целых. Часы дёргаются раз в
  # TICK_MASK+1 операций, печать — не чаще раза в INTERVAL секунд: на миллионе
  # заявок это десятки строк и доли процента времени.
  class Progress
    TICK_MASK = 0xFFF # 4096 операций между взглядами на часы
    INTERVAL = 2.0    # не чаще одной строки в две секунды

    # Прогресс выключен: те же вызовы, ноль работы. Runner не обрастает
    # проверками на nil, а бенчмарк без --progress не платит ничего.
    class Null
      def stage(_label) = nil
      def tick(_seen) = nil
      def finish_stage = nil
    end

    def initialize(io:, total: nil, clock: Measurement.method(:now))
      @io = io
      @total = total
      @clock = clock
      @stage_started = nil
      @stage_label = nil
      @last_tick = nil
      @stage_index = 0
    end

    # Границы этапов: предыдущий закрывается со своим временем, новый
    # объявляется. Так видно и то, где мы сейчас, и то, что уже позади.
    def stage(label)
      finish_stage
      @stage_index += 1
      @stage_label = label
      @stage_started = @clock.call
      @last_tick = @stage_started
      write("[#{@stage_index}] #{label}...")
    end

    def finish_stage
      return if @stage_label.nil?

      elapsed = format_seconds(@clock.call - @stage_started)
      write("[#{@stage_index}] #{@stage_label}: готово за #{elapsed}")
      @stage_label = nil
    end

    def tick(seen)
      return unless seen.nobits?(TICK_MASK)

      now = @clock.call
      return if now - @last_tick < INTERVAL

      @last_tick = now
      write(tick_line(seen, now - @stage_started))
    end

    private

    def tick_line(seen, elapsed)
      rate = elapsed.zero? ? 0 : (seen / elapsed).round
      "  #{group(seen)}#{of_total(seen)}, #{group(rate)} оп/с#{eta(seen, rate)}"
    end

    def of_total(seen)
      return '' if @total.nil? || @total.zero?

      " из #{group(@total)} (#{(seen * 100.0 / @total).round}%)"
    end

    # Оценка по средней скорости с начала этапа. Честно называется «осталось ~»:
    # скорость плавает — по мере выборки дневных лимитов пул кандидатов сужается,
    # и заявки начинают считаться быстрее.
    def eta(seen, rate)
      return '' if @total.nil? || rate.zero? || seen >= @total

      ", осталось ~#{format_seconds((@total - seen).fdiv(rate))}"
    end

    def format_seconds(seconds)
      return "#{seconds.round(1)} с" if seconds < 60

      minutes, rest = seconds.divmod(60)
      "#{minutes.to_i} м #{rest.round} с"
    end

    def group(number) = number.to_s.reverse.scan(/\d{1,3}/).join(' ').reverse

    def write(line)
      @io.puts(line)
      @io.flush
    end
  end
end
