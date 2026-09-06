# frozen_string_literal: true

module Reporting
  # Секция routing_report.json про второй проход (Execution::PendingResolutionPass).
  # Строится из уже посчитанного Report и снимка "projected_daily_utilization"
  # ДО статус-чека (тот же Reporting::Utilization.projected_daily, что уже
  # идёт в основной отчёт) — секция не пересчитывает первый проход заново,
  # только показывает дельту, которую внёс второй.
  #
  # Ключ в отчёте отсутствует вовсе, когда второй проход выключен конфигом
  # (pending_resolution.enabled: false в config/routing.yml) — bin/route в
  # этом случае не строит секцию и не передаёт её в Reporting::ReportBuilder,
  # как comparison/benchmark уже делают для своих переключателей.
  module PendingResolutionSummary
    def self.build(report, utilization_before, providers)
      {
        'checked' => report.checked,
        'resolved' => report.resolved,
        'approved' => report.approved_count,
        'rejected' => report.rejected_count,
        'still_pending' => report.still_pending.size,
        'freed_in_progress_count' => report.resolved,
        'freed_in_progress_amount' => report.freed_amount,
        'utilization' => utilization(report, utilization_before, providers)
      }
    end

    # daily_approved_amount растёт только у :approved (см. State#apply_resolution) —
    # :rejected освобождает in_progress, но дневной оборот не трогает, поэтому
    # утилизация меняется только approved-суммой позднего статус-чека.
    def self.utilization(report, before, providers)
      approved_amount_by_provider = approved_by_provider(report)
      providers.to_h do |provider|
        [provider.name, utilization_entry(provider, before,
                                          approved_amount_by_provider)]
      end
    end
    private_class_method :utilization

    def self.approved_by_provider(report)
      report.resolutions.select { |resolution| resolution.actual == :approved }
            .group_by(&:provider)
            .transform_values { |resolutions| resolutions.sum(&:amount) }
    end
    private_class_method :approved_by_provider

    def self.utilization_entry(provider, before, approved_amount_by_provider)
      prior = before.fetch(provider.name)
      delta = approved_amount_by_provider.fetch(provider.name, 0)
      used_after = prior.fetch('used') + delta
      limit = prior.fetch('limit')

      {
        'used_before' => prior.fetch('used'), 'used_after' => used_after,
        'utilization_pct_before' => prior.fetch('utilization_pct'),
        'utilization_pct_after' => utilization_pct(used_after, limit)
      }
    end
    private_class_method :utilization_entry

    def self.utilization_pct(used, limit)
      return nil if limit.nil? || limit.zero?

      (used.to_f / limit * 100).round(1)
    end
    private_class_method :utilization_pct
  end
end
