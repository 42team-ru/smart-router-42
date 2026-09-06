# frozen_string_literal: true

module Reporting
  module InputDiagnostics
    # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- диагностика показывает три независимых входа вместе.
    def self.build(queue_result, history, providers)
      errors = queue_result.errors
      queue = { 'rows' => queue_result.operations.size + errors.size,
                'accepted' => queue_result.operations.size, 'rejected' => errors.size,
                'duplicate_operation_ids' => errors.count do |e|
                  e.include?('дубль operation_id')
                end,
                'invalid_amount' => errors.count { |e| e.include?('amount должен быть') },
                'missing_required_field' => errors.count do |e|
                  e.include?('нет обязательного поля')
                end }
      {
        'queue' => queue,
        'history' => history.diagnostics,
        'providers' => { 'in_snapshot' => providers.size,
                         'with_zero_traffic_share' => providers.count do |p|
                           p.traffic_percentage.to_i.zero?
                         end,
                         'inactive' => providers.count { |p| p.status != 'active' } }
      }
    end
  end
end
