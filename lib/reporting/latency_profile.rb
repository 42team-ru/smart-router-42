# frozen_string_literal: true

module Reporting
  module LatencyProfile
    RESULTS = %w[approved rejected expired].freeze

    # rubocop:disable-next Metrics/MethodLength -- профиль намеренно собирает три связанных разреза.
    def self.build(history, source)
      rows = valid_rows(history.rows)
      return nil if rows.empty?

      by_result = profile_by_result(rows)
      by_provider = rows.group_by { |row| row['payment_system'] }.sort.to_h do |name, group|
        [name, profile(group)]
      end
      {
        'source' => source,
        'definition' => definition,
        'total' => profile(rows), 'by_result' => by_result, 'by_provider' => by_provider
      }
    end

    def self.profile_by_result(rows)
      RESULTS.to_h do |result|
        [result, profile(rows.select { |row| row['status'] == result })]
      end.compact
    end
    private_class_method :profile_by_result

    def self.definition
      'Секунды ответа по истории; строки без целой неотрицательной латентности ' \
        'или с неизвестным результатом исключены.'
    end
    private_class_method :definition

    def self.valid_rows(rows)
      rows.select { |row| RESULTS.include?(row['status']) && latency(row) }
    end
    private_class_method :valid_rows

    def self.profile(rows)
      return nil if rows.empty?

      values = rows.map { |row| latency(row) }.sort
      { 'count' => values.size, 'p50_sec' => percentile(values, 50),
        'p95_sec' => percentile(values, 95), 'min_sec' => values.first, 'max_sec' => values.last }
    end
    private_class_method :profile

    def self.percentile(values, percent)
      values[(((values.size * percent) + 99) / 100) - 1]
    end
    private_class_method :percentile

    def self.latency(row)
      value = row['latency_sec']
      return value if value.is_a?(Integer) && value >= 0
      return nil unless value.to_s.match?(/\A\d+\z/)

      value.to_i
    end
    private_class_method :latency
  end
end
