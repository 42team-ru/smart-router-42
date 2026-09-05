# frozen_string_literal: true

require 'csv'

module Io
  # Загрузчик operations_history.csv: считает наблюдаемую конверсию провайдеров.
  #
  # Паспортный conversion_24h из providers.json заявлен продавцом и не
  # совпадает с фактом. Калибровка — это approved / всего записей за
  # провайдером на всей истории, без деления на approved+rejected: expired
  # тоже расход возможности провайдера.
  module HistoryLoader
    def self.load(path)
      totals = Hash.new(0)
      approved = Hash.new(0)

      each_row(path) do |row|
        payment_system = row['payment_system']
        totals[payment_system] += 1
        approved[payment_system] += 1 if row['status'] == 'approved'
      end

      totals.to_h do |payment_system, total|
        [payment_system, conversion(approved, payment_system, total)]
      end
    end

    def self.conversion(approved, payment_system, total)
      (approved[payment_system].to_f / total).round(3)
    end

    def self.each_row(path, &)
      CSV.foreach(path, headers: true, &)
    rescue Errno::ENOENT
      raise "Файл истории операций не найден: #{path}"
    end
  end
end
