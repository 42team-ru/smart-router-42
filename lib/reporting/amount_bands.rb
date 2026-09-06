# frozen_string_literal: true

module Reporting
  module AmountBands
    BANDS = [['0-10000', 0, 10_000], ['10000-50000', 10_000, 50_000],
             ['50000-100000', 50_000, 100_000], ['100000+', 100_000, nil]].freeze
    RESULTS = %w[approved rejected expired].freeze

    # rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength -- каждая полоса строится одинаково из двух источников.
    def self.build(pairs, history)
      bands = BANDS.filter_map do |label, from, to|
        current = pairs.select { |operation, _| inside?(operation.amount, from, to) }
        historical = history.rows.select do |row|
          amount = integer(row['amount'])
          amount && RESULTS.include?(row['status']) && inside?(amount, from, to)
        end
        next if current.empty? && historical.empty?

        [label, entry(from, to, current, historical)]
      end.to_h
      { 'definition' => 'Полосы сумм в рублях: нижняя граница включается, верхняя не включается.',
        'bands' => bands }
    end

    # rubocop:disable-next Metrics/AbcSize -- запись объединяет распределение прогона и историю одной полосы.
    def self.entry(from, to, pairs, rows)
      providers = pairs.group_by { |_, outcome| outcome.selected.name }.sort.to_h do |name, group|
        [name, { 'count' => group.size, 'share_pct' => percentage(group.size, pairs.size) }]
      end
      by_provider = rows.group_by { |row| row['payment_system'] }.sort.to_h do |name, group|
        [name, history_entry(group)]
      end
      { 'range' => { 'from' => from, 'to' => to }, 'operations' => pairs.size,
        'distribution' => providers,
        'history' => history_entry(rows).merge('by_provider' => by_provider) }
    end
    private_class_method :entry

    def self.history_entry(rows)
      approved = rows.count { |row| row['status'] == 'approved' }
      { 'observations' => rows.size, 'approved_share_pct' => percentage(approved, rows.size) }
    end
    private_class_method :history_entry

    def self.inside?(amount, from, to) = amount >= from && (to.nil? || amount < to)
    private_class_method :inside?

    def self.integer(value) = Integer(value, exception: false)
    private_class_method :integer

    def self.percentage(part, total)
      return 0.0 if total.zero?

      Rational(part * 100, total).round(1).to_f
    end
    private_class_method :percentage
  end
end
