# frozen_string_literal: true

require 'reporting/pending_resolution_summary'
require 'execution/pending_resolution_pass'

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength -- каждый пример проверяет
# форму всей секции отчёта разом, а не отдельное поле.
RSpec.describe Reporting::PendingResolutionSummary do
  let(:vipay) { build_provider('vipay', daily_amount_limit: 5_000_000) }
  let(:quickpay) { build_provider('quickpay', daily_amount_limit: 8_000_000) }
  let(:spacepayments) { build_spacepayments(daily_amount_limit: nil) }
  let(:providers) { [vipay, quickpay, spacepayments] }

  let(:utilization_before) do
    {
      'vipay' => { 'used' => 3_200_000, 'limit' => 5_000_000, 'utilization_pct' => 64.0 },
      'quickpay' => { 'used' => 1_000_000, 'limit' => 8_000_000, 'utilization_pct' => 12.5 },
      'spacepayments' => { 'used' => 0, 'limit' => nil, 'utilization_pct' => nil }
    }
  end

  def resolution(provider:, actual:, amount:)
    Execution::PendingResolutionPass::Resolution.new(
      operation_id: 'op_1', provider: provider, attempt_no: -1, actual: actual, amount: amount
    )
  end

  describe '.build' do
    it 'считает checked/resolved/approved/rejected/still_pending и свободившуюся ёмкость' do
      report = Execution::PendingResolutionPass::Report.new(
        resolutions: [
          resolution(provider: 'quickpay', actual: :approved, amount: 150_000),
          resolution(provider: 'vipay', actual: :rejected, amount: 20_000)
        ],
        still_pending: [resolution(provider: 'quickpay', actual: :expired, amount: 5_000)]
      )

      summary = described_class.build(report, utilization_before, providers)

      expect(summary).to include(
        'checked' => 3, 'resolved' => 2, 'approved' => 1, 'rejected' => 1, 'still_pending' => 1,
        'freed_in_progress_count' => 2, 'freed_in_progress_amount' => 170_000
      )
    end

    it 'растит used_after только на approved-суммы своего провайдера' do
      report = Execution::PendingResolutionPass::Report.new(
        resolutions: [
          resolution(provider: 'quickpay', actual: :approved, amount: 150_000),
          resolution(provider: 'vipay', actual: :rejected, amount: 20_000)
        ],
        still_pending: []
      )

      summary = described_class.build(report, utilization_before, providers)

      expect(summary['utilization']).to eq(
        'vipay' => { 'used_before' => 3_200_000, 'used_after' => 3_200_000,
                     'utilization_pct_before' => 64.0, 'utilization_pct_after' => 64.0 },
        'quickpay' => { 'used_before' => 1_000_000, 'used_after' => 1_150_000,
                        'utilization_pct_before' => 12.5, 'utilization_pct_after' => 14.4 },
        'spacepayments' => { 'used_before' => 0, 'used_after' => 0,
                             'utilization_pct_before' => nil, 'utilization_pct_after' => nil }
      )
    end

    it 'без резолюций utilization_after совпадает с utilization_before' do
      report = Execution::PendingResolutionPass::Report.new(resolutions: [], still_pending: [])

      summary = described_class.build(report, utilization_before, providers)

      expect(summary).to include('checked' => 0, 'resolved' => 0, 'approved' => 0, 'rejected' => 0,
                                 'still_pending' => 0, 'freed_in_progress_amount' => 0)
      expect(summary['utilization']['vipay']['used_after']).to eq(3_200_000)
    end

    it 'nil-лимит (spacepayments) не делится на ноль -- utilization_pct_after остаётся nil' do
      report = Execution::PendingResolutionPass::Report.new(
        resolutions: [resolution(provider: 'spacepayments', actual: :approved, amount: 1_000)],
        still_pending: []
      )

      summary = described_class.build(report, utilization_before, providers)

      expect(summary['utilization']['spacepayments']).to eq(
        'used_before' => 0, 'used_after' => 1_000,
        'utilization_pct_before' => nil, 'utilization_pct_after' => nil
      )
    end
  end
end
# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength
