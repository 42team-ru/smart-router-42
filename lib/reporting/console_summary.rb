# frozen_string_literal: true

module Reporting
  # D-1: читаемый вывод bin/route в терминал. Ничего не считает заново —
  # только форматирует то, что уже посчитано пайплайном (pairs) и
  # Reporting::ReportBuilder (report). "Выигравшая" попытка — последняя с
  # decision == 'selected': неудачные реальные попытки каскада тоже
  # кодируются 'selected' с собственными attempt_no/result (формат
  # attempts заморожен валидатором организаторов), поэтому последняя из них
  # и есть решившая исход операции.
  module ConsoleSummary
    def self.operation_lines(pairs)
      pairs.map { |operation, outcome| operation_line(operation, outcome) }
    end

    def self.operation_line(operation, outcome)
      attempt = winning_attempt(outcome)
      "#{operation.operation_id}  #{format_amount(operation.amount)} ₽ → " \
        "#{outcome.selected.name} (#{outcome.result})  " \
        "#{attempt.reason}: #{attempt.details}"
    end
    private_class_method :operation_line

    def self.winning_attempt(outcome)
      outcome.attempts.select { |attempt| attempt.decision == 'selected' }.last
    end
    private_class_method :winning_attempt

    def self.summary_lines(report)
      [
        '',
        'Итог (факт / цель / достижимо):',
        *distribution_lines(report),
        '',
        fallback_line(report),
        benchmark_line(report),
        *analytics_lines(report)
      ]
    end

    def self.distribution_lines(report)
      report.fetch('distribution').map { |name, entry| distribution_line(name, entry) }
    end
    private_class_method :distribution_lines

    def self.distribution_line(name, entry)
      achievable = entry['achievable_pct'].nil? ? '—' : "#{entry['achievable_pct']}%"
      "  #{name}: #{entry['count']} (#{entry['share_pct']}% / #{entry['target_pct']}% / " \
        "#{achievable})"
    end
    private_class_method :distribution_line

    def self.fallback_line(report)
      fallback = report.fetch('fallback')
      "Fallback: #{fallback['first_attempt_success']} с первой попытки, " \
        "#{fallback['recovered_by_fallback']} восстановлено каскадом, " \
        "#{fallback['spacepayments_used']} в spacepayments, " \
        "#{fallback['cascade_exhausted']} каскад исчерпан"
    end
    private_class_method :fallback_line

    def self.benchmark_line(report)
      benchmark = report.fetch('benchmark')
      ratio = benchmark['competitive_ratio']
      bound = benchmark.dig('offline_bound', 'max_deviation_pp')
      ours = benchmark.dig('our_online_result', 'max_deviation_pp')
      "Benchmark: competitive_ratio=#{ratio.nil? ? 'н/д' : ratio} " \
        "(эталон #{bound.nil? ? 'н/д' : bound} п.п., наш #{ours.nil? ? 'н/д' : ours} п.п.)"
    end
    private_class_method :benchmark_line

    def self.analytics_lines(report)
      report.fetch('deviation_causes').map { |cause| "Причина отклонения: #{cause}" } +
        report.fetch('recommendations').map { |rec| "Рекомендация: #{rec}" }
    end
    private_class_method :analytics_lines

    def self.format_amount(amount)
      amount.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1 ').reverse
    end
    private_class_method :format_amount
  end
end
