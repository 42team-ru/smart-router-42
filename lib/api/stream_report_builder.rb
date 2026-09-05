# frozen_string_literal: true

require_relative '../domain/operation'
require_relative '../execution/outcome'
require_relative '../routing/attempt'
require_relative '../reporting/report_builder'

module Api
  # Собирает routing_report из строк SQLite. Форма отчёта — байт-в-байт то же,
  # что у Reporting::ReportBuilder (единственный источник правды), поэтому мы
  # пересобираем пары (Operation, Outcome) из строк и отдаём их в тот же
  # ReportBuilder. Спека Api сверяет deep-equal.
  module StreamReportBuilder
    def self.build(repo:, providers:, strategy:, filter: {}, history: {})
      raw = repo.fetch_all_for_report(filter: filter)
      providers_by_name = providers.to_h { |provider| [provider.name, provider] }
      pairs = raw.map { |row| build_pair(row, providers_by_name) }
      Reporting::ReportBuilder.build(
        pairs, providers: providers, history: history, strategy: strategy
      )
    end

    def self.build_pair(row, providers_by_name)
      decision = row[:decision]
      operation = Domain::Operation.new(
        operation_id: decision['operation_id'],
        created_at: decision['created_at_iso'] || Time.at(decision['created_at']).iso8601,
        amount: decision['amount'],
        bank: decision['bank'],
        card_brand: decision['card_brand'],
        payout_requisite: {}
      )
      outcome = Execution::Outcome.new(
        selected: providers_by_name.fetch(decision['selected_provider']),
        attempts: row[:attempts].map { |a| build_attempt(a) },
        result: decision['simulated_result'].to_sym
      )
      [operation, outcome]
    end

    def self.build_attempt(row)
      Routing::Attempt.new(
        provider: row['provider'],
        decision: row['decision'],
        reason: row['reason'],
        details: row['details'],
        strategy: row['strategy'],
        attempt_no: row['decision'] == 'selected' ? row['attempt_no'] : nil,
        result: row['decision'] == 'selected' ? row['result'] : nil
      )
    end
  end
end
