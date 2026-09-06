# frozen_string_literal: true

require 'sqlite3'
require 'fileutils'
require 'json'
require 'time'
require_relative '../domain/operation'
require_relative '../execution/outcome'
require_relative '../routing/attempt'

module Api
  # Тонкая обёртка над SQLite. Хранит decisions + attempts, применяет retention,
  # умеет отдать сырой список решений и пересобрать пары (Operation, Outcome)
  # для потокового отчёта. Персистентность аналитики — единственная причина
  # существования; state провайдеров тут не хранится.
  #
  # Все SELECT'ы упорядочены (по id/attempt_no) — гарантия детерминизма выдачи.
  class DecisionsRepo
    SCHEMA_STATEMENTS = [
      <<~SQL,
        CREATE TABLE IF NOT EXISTS decisions (
          id                INTEGER PRIMARY KEY AUTOINCREMENT,
          operation_id      TEXT    NOT NULL,
          created_at        INTEGER NOT NULL,
          merchant_id       TEXT    NOT NULL,
          gate              TEXT    NOT NULL,
          amount            INTEGER NOT NULL,
          bank              TEXT,
          card_brand        TEXT,
          selected_provider TEXT,
          simulated_result  TEXT    NOT NULL,
          latency_sec       INTEGER,
          strategy          TEXT,
          created_at_iso    TEXT
        )
      SQL
      'CREATE INDEX IF NOT EXISTS idx_dec_created  ON decisions(created_at)',
      'CREATE INDEX IF NOT EXISTS idx_dec_provider ON decisions(selected_provider)',
      'CREATE INDEX IF NOT EXISTS idx_dec_merchant ON decisions(merchant_id)',
      'CREATE INDEX IF NOT EXISTS idx_dec_gate     ON decisions(gate)',
      <<~SQL,
        CREATE TABLE IF NOT EXISTS attempts (
          decision_id INTEGER NOT NULL REFERENCES decisions(id) ON DELETE CASCADE,
          attempt_no  INTEGER NOT NULL,
          provider    TEXT    NOT NULL,
          decision    TEXT    NOT NULL,
          reason      TEXT    NOT NULL,
          details     TEXT    NOT NULL,
          result      TEXT,
          strategy    TEXT,
          PRIMARY KEY (decision_id, attempt_no)
        )
      SQL
      'CREATE INDEX IF NOT EXISTS idx_att_reason ON attempts(reason)'
    ].freeze

    def initialize(path:, retention_seconds:)
      @path = path
      @retention_seconds = retention_seconds
      FileUtils.mkdir_p(File.dirname(path)) unless path == ':memory:'
      @db = SQLite3::Database.new(path)
      @db.results_as_hash = true
      configure_pragmas
      apply_schema
    end

    def close
      @db.close
    end

    # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength
    def insert(operation:, outcome:, merchant:, gate:, strategy:, now: Time.now.to_i)
      selected_name = outcome.selected&.name
      latency = outcome.selected&.avg_latency_sec
      created_ts = parse_ts(operation.created_at, fallback: now)

      @db.transaction do
        @db.execute(
          'INSERT INTO decisions
             (operation_id, created_at, merchant_id, gate, amount, bank, card_brand,
              selected_provider, simulated_result, latency_sec, strategy, created_at_iso)
           VALUES (?,?,?,?,?,?,?,?,?,?,?,?)',
          [operation.operation_id, created_ts, merchant, gate, operation.amount,
           operation.bank, operation.card_brand, selected_name, outcome.result.to_s,
           latency, strategy, operation.created_at.to_s]
        )
        decision_id = @db.last_insert_row_id
        outcome.attempts.each_with_index do |attempt, index|
          insert_attempt(decision_id, index + 1, attempt)
        end
      end
      apply_retention!(now)
    end

    def count(filter = {})
      where, params = build_where(filter)
      @db.get_first_value("SELECT COUNT(*) FROM decisions #{where}", params).to_i
    end

    def clear
      @db.execute('DELETE FROM decisions')
    end

    # Возвращает decision-хеши в формате routing_decisions_test.json[i].
    def list(filter: {}, limit: 100, offset: 0)
      where, params = build_where(filter)
      rows = @db.execute(
        "SELECT * FROM decisions #{where} ORDER BY id ASC LIMIT ? OFFSET ?",
        params + [limit, offset]
      )
      attempts_by_id = load_attempts(rows.map { |r| r['id'] })
      rows.map { |row| decision_hash(row, attempts_by_id[row['id']] || []) }
    end

    # Решения с контекстом операции: те же поля, что в /decisions, плюс id,
    # время, сумма, банк, мерчант и гейт. Отдельный метод, а не расширение
    # decision_hash: форма /decisions зафиксирована как элемент
    # routing_decisions_test.json и обрастать полями не должна.
    def list_with_context(filter: {}, limit: 100, offset: 0)
      where, params = build_where(filter)
      rows = @db.execute(
        "SELECT * FROM decisions #{where} ORDER BY id ASC LIMIT ? OFFSET ?",
        params + [limit, offset]
      )
      attempts_by_id = load_attempts(rows.map { |r| r['id'] })
      rows.map { |row| context_decision_hash(row, attempts_by_id[row['id']] || []) }
    end

    # Плоские строки для агрегатов консоли. Отдаём только то, из чего считается
    # сводка, — гонять сюда attempts и details незачем.
    def analytics_decisions(filter = {})
      where, params = build_where(filter)
      @db.execute(
        "SELECT id, created_at, amount, selected_provider, simulated_result, latency_sec
           FROM decisions #{where} ORDER BY id ASC", params
      )
    end

    def analytics_attempts(filter = {})
      # Колонки фильтра (merchant_id, gate, selected_provider, created_at)
      # есть только в decisions, поэтому WHERE из build_where подставляется
      # в JOIN без префиксов и без двусмысленности.
      where, params = build_where(filter)
      @db.execute(
        "SELECT a.decision_id, a.provider, a.decision, d.created_at
           FROM attempts a JOIN decisions d ON d.id = a.decision_id
           #{where} ORDER BY a.decision_id ASC, a.attempt_no ASC", params
      )
    end

    def fetch_all_for_report(filter: {})
      where, params = build_where(filter)
      rows = @db.execute(
        "SELECT * FROM decisions #{where} ORDER BY id ASC", params
      )
      attempts_by_id = load_attempts(rows.map { |r| r['id'] })
      rows.map { |row| { decision: row, attempts: attempts_by_id[row['id']] || [] } }
    end

    def apply_retention!(now)
      return unless @retention_seconds.positive?

      cutoff = now - @retention_seconds
      @db.execute('DELETE FROM decisions WHERE created_at < ?', [cutoff])
    end

    private

    def configure_pragmas
      @db.execute('PRAGMA foreign_keys = ON')
      @db.execute('PRAGMA journal_mode = WAL') unless @path == ':memory:'
    end

    def apply_schema
      SCHEMA_STATEMENTS.each { |stmt| @db.execute_batch(stmt) }
    end

    def insert_attempt(decision_id, attempt_no, attempt)
      provider = attempt.provider.respond_to?(:name) ? attempt.provider.name : attempt.provider
      @db.execute(
        'INSERT INTO attempts
           (decision_id, attempt_no, provider, decision, reason, details, result, strategy)
         VALUES (?,?,?,?,?,?,?,?)',
        [decision_id, attempt_no, provider, attempt.decision, attempt.reason,
         attempt.details, attempt.result, attempt.strategy]
      )
    end

    def load_attempts(decision_ids)
      return {} if decision_ids.empty?

      placeholders = (['?'] * decision_ids.size).join(',')
      rows = @db.execute(
        "SELECT * FROM attempts WHERE decision_id IN (#{placeholders})
           ORDER BY decision_id ASC, attempt_no ASC",
        decision_ids
      )
      rows.group_by { |r| r['decision_id'] }
    end

    def decision_hash(row, attempts)
      {
        'operation_id' => row['operation_id'],
        'selected_provider' => row['selected_provider'],
        'attempts' => attempts.map { |a| attempt_hash(a) },
        'simulated_result' => row['simulated_result'],
        'latency_sec' => row['latency_sec']
      }
    end

    def context_decision_hash(row, attempts)
      decision_hash(row, attempts).merge(
        'id' => row['id'],
        'created_at' => Time.at(row['created_at']).utc.iso8601,
        'amount' => row['amount'],
        'bank' => row['bank'],
        'card_brand' => row['card_brand'],
        'merchant' => row['merchant_id'],
        'gate' => row['gate']
      )
    end

    def attempt_hash(row)
      hash = {
        'provider' => row['provider'],
        'decision' => row['decision'],
        'reason' => row['reason'],
        'details' => row['details']
      }
      hash['strategy'] = row['strategy'] unless row['strategy'].nil?
      hash['attempt_no'] = row['attempt_no'] if row['decision'] == 'selected'
      hash['result'] = row['result'] if row['decision'] == 'selected' && !row['result'].nil?
      hash
    end

    FILTER_MAP = {
      merchant: 'merchant_id = ?',
      gate: 'gate = ?',
      provider: 'selected_provider = ?',
      since: 'created_at >= ?',
      until: 'created_at < ?'
    }.freeze

    def build_where(filter)
      clauses = []
      params = []
      filter.each do |key, value|
        next if value.nil?

        sql = FILTER_MAP[key.to_sym]
        next unless sql

        clauses << sql
        params << value
      end
      [clauses.empty? ? '' : "WHERE #{clauses.join(' AND ')}", params]
    end

    def parse_ts(iso, fallback:)
      return fallback if iso.nil?

      Time.parse(iso.to_s).to_i
    rescue ArgumentError
      fallback
    end
  end
end
