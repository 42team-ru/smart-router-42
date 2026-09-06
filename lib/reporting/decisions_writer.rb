# frozen_string_literal: true

require 'json'

module Reporting
  # Сборка routing_decisions.json из уже готовых решений.
  #
  # Здесь нет логики допуска или каскада — только форма файла. Вход:
  # пары (Domain::Operation, Execution::Outcome), уже посчитанные
  # Routing (RoutePlan/Violation) и Execution (Outcome).
  module DecisionsWriter
    def self.build_decision(operation, outcome)
      {
        'operation_id' => operation.operation_id,
        'selected_provider' => outcome.selected.name,
        'attempts' => outcome.attempts.map(&:to_h),
        'simulated_result' => outcome.result.to_s,
        'latency_sec' => outcome.selected.avg_latency_sec
      }
    end

    def self.build(pairs)
      pairs.map { |operation, outcome| build_decision(operation, outcome) }
    end

    # Правило воспроизводимости: один завершающий перевод строки, никаких
    # лишних — иначе make determinism будет мигать.
    #
    # Пишем потоком, а не JSON.pretty_generate(build(pairs)) целиком: на
    # очереди в миллион операций материализация решений и сборка
    # гигабайтной строки перед записью — главный источник пикового расхода
    # памяти CLI (см. пакет 3). Каждое решение сериализуется отдельным
    # вызовом JSON.pretty_generate и вклеивается в общий массив с отступом
    # в два пробела — ровно так JSON.pretty_generate индентирует элемент
    # массива на первом уровне вложенности, поэтому байт в байт
    # неотличимо от прежнего JSON.pretty_generate(build(pairs)).
    def self.write(path, pairs)
      File.open(path, 'w') do |file|
        next file.write("[]\n") if pairs.empty?

        write_elements(file, pairs)
      end
    end

    def self.write_elements(file, pairs)
      file.write('[')
      pairs.each_with_index do |(operation, outcome), index|
        file.write(index.zero? ? "\n" : ",\n")
        file.write(indented_decision(build_decision(operation, outcome)))
      end
      file.write("\n]\n")
    end
    private_class_method :write_elements

    def self.indented_decision(decision)
      JSON.pretty_generate(decision).each_line.map { |line| "  #{line}" }.join
    end
    private_class_method :indented_decision
  end
end
