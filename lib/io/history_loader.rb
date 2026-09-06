# frozen_string_literal: true

require 'csv'
require_relative 'history_stats'

module Io
  # Загрузчик operations_history.csv: три исхода (approved/rejected/expired) на
  # провайдера, сглаженные к общему среднему по методу Дирихле (partial
  # pooling / эмпирический Байес — не нейросеть, доверять числу можно и на
  # бумаге).
  #
  # Раньше калибровка была "approved / всего", без учёта размера выборки: у
  # payflow в reference/data/operations_history.csv всего 19 наблюдений, у
  # vipay — 41, а делёж давал одинаково уверенные на вид доли. 95%-й интервал
  # Уилсона для 9/19 — примерно [0.27, 0.68], шире всего разброса между
  # провайдерами; воспринимать 0.474 как точную цифру нечестно.
  #
  # Формула на провайдера:
  #   p(исход) = (счётчик_исхода + pooled_исход × k) / (n_провайдера + k)
  # pooled_исход — доля исхода по ВСЕЙ истории (все провайдеры вместе). При
  # маленькой выборке (n << k) оценка тянется к pooled_исход; при большой
  # (n >> k) сжатие исчезает само — это и есть суть partial pooling.
  #
  # k не подобран на глаз, а выведен из данных методом моментов:
  #   k = mu × (1 − mu) / var − 1
  # mu — общая доля approved по всей истории (сумма approved / сумма всех
  # наблюдений, а не среднее по провайдерам — крупная выборка должна весить
  # больше). var — дисперсия ДОЛЕЙ approved МЕЖДУ ПРОВАЙДЕРАМИ (по числу
  # провайдеров, то есть смещённая оценка: var = Σ(p_i − mu)² / N). Смысл: чем
  # сильнее провайдеры на самом деле отличаются друг от друга (большой var),
  # тем меньше оснований тянуть их друг к другу (маленький k), и наоборот.
  #
  # Всё считается через Rational — решающий путь дробей во float не терпит
  # (scripts/check_determinism.sh и общий инвариант проекта), а сглаживание по
  # природе своей дробное. В базисные пункты (approved_bp/rejected_bp/
  # expired_bp) переводим только на выходе, округляя Rational#round.
  # rubocop:disable-next Metrics/ModuleLength -- разбор CSV и единая калибровка неразделимы по контракту.
  module HistoryLoader
    STATUSES = %i[approved rejected expired].freeze
    BASIS_POINTS = 10_000

    # outcomes.smoothing: false в конфиге — сырые доли без Дирихле, чтобы на
    # защите можно было сравнить эффект сглаживания явным переключением. k
    # всё равно считается (нужен для отображения), но не участвует в
    # approved_bp/rejected_bp/expired_bp.
    def self.load(path, smoothing: true)
      rows = []
      each_row(path) { |row| rows << row }
      build_stats(tally(rows), smoothing: smoothing, rows: rows)
    end

    def self.tally(rows)
      counts = Hash.new { |hash, name| hash[name] = Hash.new(0) }
      rows.each { |row| tally_row(counts, row) }
      counts
    end
    private_class_method :tally

    def self.tally_row(counts, row)
      payment_system = row['payment_system']
      status = row['status']
      return unless valid_status?(status)

      counts[payment_system][status.to_sym] += 1
    end
    private_class_method :tally_row

    def self.valid_status?(status)
      STATUSES.map(&:to_s).include?(status)
    end
    private_class_method :valid_status?

    # rubocop:disable Metrics/MethodLength -- создание статистики и диагностики обязано читать один набор строк.
    def self.build_stats(counts, smoothing:, rows: [])
      totals = totals_by_provider(counts)
      total_obs = totals.values.sum
      diagnostics = build_diagnostics(rows)

      if total_obs.zero?
        return Io::HistoryStats.new(entries: {}, k: 0, smoothed: smoothing, rows: rows,
                                    diagnostics: diagnostics)
      end

      pooled = pooled_shares(counts, total_obs)
      k_value = k_from_moments(counts, totals, pooled.fetch(:approved))
      entries = counts.to_h do |name, outcome_counts|
        [name,
         build_entry(outcome_counts, totals.fetch(name), pooled, k_value, smoothing: smoothing)]
      end
      bank_entries = build_bank_entries(rows, entries, k_value, smoothing)
      Io::HistoryStats.new(entries: entries, k: k_value, smoothed: smoothing, rows: rows,
                           diagnostics: diagnostics, bank_entries: bank_entries)
    end
    private_class_method :build_stats
    # rubocop:enable Metrics/MethodLength

    def self.build_diagnostics(rows)
      {
        'rows' => rows.size,
        'unparsable_latency' => rows.count { |row| parse_latency(row['latency_sec']).nil? },
        'unknown_result' => rows.count { |row| !valid_status?(row['status']) },
        'providers_seen' => rows.filter_map { |row| row['payment_system'] }.uniq.sort
      }
    end
    private_class_method :build_diagnostics

    def self.parse_latency(value)
      return value if value.is_a?(Integer) && value >= 0
      return nil unless value.to_s.match?(/\A\d+\z/)

      value.to_i
    end
    private_class_method :parse_latency

    def self.totals_by_provider(counts)
      counts.transform_values { |outcome_counts| outcome_counts.values.sum }
    end
    private_class_method :totals_by_provider

    # pooled_исход = доля исхода по всей истории сразу (сумма счётчиков исхода
    # по всем провайдерам / сумма всех наблюдений) — общий знаменатель для
    # приора Дирихле.
    def self.pooled_shares(counts, total_obs)
      STATUSES.to_h do |status|
        total = counts.values.sum { |outcome_counts| outcome_counts[status] }
        [status, Rational(total, total_obs)]
      end
    end
    private_class_method :pooled_shares

    # k = mu(1-mu)/var - 1, метод моментов. var считается вокруг ТОГО ЖЕ mu
    # (общая доля approved по всей истории), а не вокруг среднего долей
    # провайдеров — иначе k не совпадёт с контрольными числами и не будет
    # согласован с pooled-долями, к которым и идёт сглаживание.
    #
    # var == 0 (0 или 1 провайдер в истории, либо у всех совпадающая доля) —
    # разброса измерить не из чего, k = 0 (сглаживание вырождается в сырые
    # доли — с одним провайдером тянуть не к чему, это не костыль, а точный
    # предел формулы). Отрицательный k (var больше, чем допускает биномиальная
    # дисперсия при общем mu) — тоже 0: пула, к которому имеет смысл тянуть,
    # попросту нет, случай не покрыт контрольными числами, но не должен ронять
    # загрузку.
    def self.k_from_moments(counts, totals, mu_rate)
      return 0 if counts.size < 2

      var = variance_of_approved_shares(counts, totals, mu_rate)
      return 0 if var.zero?

      raw = (mu_rate * (1 - mu_rate) / var) - 1
      raw.negative? ? 0 : raw
    end
    private_class_method :k_from_moments

    def self.variance_of_approved_shares(counts, totals, mu_rate)
      sum_of_squares = counts.keys.sum do |name|
        p_i = Rational(counts[name][:approved], totals.fetch(name))
        (p_i - mu_rate)**2
      end
      sum_of_squares / counts.size
    end
    private_class_method :variance_of_approved_shares

    def self.build_entry(outcome_counts, obs, pooled, k_value, smoothing:)
      bp = STATUSES.to_h do |status|
        [status, outcome_bp(outcome_counts[status], obs, pooled.fetch(status), k_value, smoothing)]
      end
      Io::HistoryStats::Entry.new(
        n: obs, approved_count: outcome_counts[:approved],
        rejected_count: outcome_counts[:rejected], expired_count: outcome_counts[:expired],
        approved_bp: bp.fetch(:approved), rejected_bp: bp.fetch(:rejected),
        expired_bp: bp.fetch(:expired)
      )
    end
    private_class_method :build_entry

    # Три компоненты (approved/rejected/expired) округляются НЕЗАВИСИМО, а не
    # через остаток -- сумма по провайдеру может разойтись с 10_000 на ±1 бп
    # (независимое округление трёх долей иначе не бывает). Это не портит
    # пороги Deterministic: там используются approved_bp и rejected_bp,
    # expired всегда "иначе" по остатку броска, а не по этому числу.
    def self.outcome_bp(raw_count, obs, pooled_share, k_value, smoothing)
      share = if smoothing
                smoothed_share(raw_count, obs, pooled_share,
                               k_value)
              else
                Rational(raw_count, obs)
              end
      (share * BASIS_POINTS).round
    end
    private_class_method :outcome_bp

    def self.smoothed_share(raw_count, obs, pooled_share, k_value)
      (Rational(raw_count) + (pooled_share * k_value)) / (obs + k_value)
    end
    private_class_method :smoothed_share

    def self.each_row(path, &)
      return CSV.foreach(path, headers: true) unless block_given?

      CSV.foreach(path, headers: true, &)
    rescue Errno::ENOENT
      raise "Файл истории операций не найден: #{path}"
    end
    private_class_method :each_row

    def self.build_bank_entries(rows, provider_entries, k_value, smoothing)
      grouped = rows.select { |row| valid_status?(row['status']) && row['bank'] }
                    .group_by { |row| [row['payment_system'], row['bank']] }
      grouped.to_h do |key, bank_rows|
        counts = STATUSES.to_h do |status|
          [status, bank_rows.count { |row| row['status'] == status.to_s }]
        end
        prior = provider_entries.fetch(key.first)
        n = bank_rows.size
        bp = STATUSES.to_h do |status|
          raw = counts.fetch(status)
          prior_share = Rational(prior.public_send("#{status}_bp"), BASIS_POINTS)
          share = smoothing ? (Rational(raw) + (prior_share * k_value)) / (n + k_value) : Rational(raw, n)
          [status, (share * BASIS_POINTS).round]
        end
        [key, Io::HistoryStats::Entry.new(n: n, approved_count: counts[:approved],
                                          rejected_count: counts[:rejected], expired_count: counts[:expired],
                                          approved_bp: bp[:approved], rejected_bp: bp[:rejected], expired_bp: bp[:expired])]
      end
    end
    private_class_method :build_bank_entries
  end
end
