# frozen_string_literal: true

require 'json'
require_relative 'queue_loader'

module Io
  # IO-2b: очередь в формате JSONL (объект на строку) для уровней синтетического
  # бенчмарка, где N слишком велико для JSON.parse(File.read(path)) целиком
  # (Io::QueueLoader) — на миллионах строк это гигабайты текста плюс кратно
  # больше в объектах Ruby разом.
  #
  # each — единственный публичный метод намеренно: возвращает валидные
  # Domain::Operation по одной через блок, не копит массив. .load (как у
  # QueueLoader) для больших уровней бы свёл на нет весь смысл потоковости.
  #
  # dedupe: false по умолчанию — без него нужен хеш на все увиденные id
  # (на 20 млн строк это сотни мегабайт ради проверки, которую генератор и
  # так не нарушает по построению, см. lib/synthetic/queue.rb). Кто явно
  # просит dedupe: true, получает точно то же поведение, что и QueueLoader
  # (дубль в errors, первое вхождение остаётся).
  module QueueStreamLoader
    Stats = Data.define(:valid, :errors)

    # rubocop:disable-next Metrics/MethodLength
    def self.each(path, dedupe: false)
      seen = dedupe ? {} : nil
      valid = 0
      errors = []
      each_line(path) do |raw, index|
        reason = QueueRecord.rejection_reason(raw)
        if reason
          errors << "operation[#{index}]: #{reason}"
        elsif seen && seen[raw['operation_id']]
          errors << "operation[#{index}]: дубль operation_id #{raw['operation_id']}, " \
                    'оставлено первое решение'
        else
          seen[raw['operation_id']] = true if seen
          valid += 1
          yield QueueRecord.build(raw)
        end
      end
      Stats.new(valid: valid, errors: errors)
    end

    def self.each_line(path)
      File.foreach(path).with_index do |line, index|
        stripped = line.strip
        next if stripped.empty?

        yield parse_line(stripped, index), index
      end
    rescue Errno::ENOENT
      raise "Файл очереди не найден: #{path}"
    end

    def self.parse_line(line, index)
      JSON.parse(line)
    rescue JSON::ParserError => e
      raise "Битый JSON в строке #{index} файла очереди: #{e.message}"
    end
    private_class_method :each_line, :parse_line
  end
end
