# frozen_string_literal: true

require 'json'
require 'tmpdir'
require 'reporting/report_builder'
require 'domain/operation'
require 'domain/provider'
require 'routing/attempt'
require 'execution/outcome'

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers
# -- каждый пример собирает отчёт из нескольких заявок и проверяет связанные утверждения об
# одном и том же файле, дробить их — терять контекст сценария
RSpec.describe Reporting::ReportBuilder do
  def build_provider(name, **attrs)
    Domain::Provider.new(
      payment_system: name, status: 'active', priority: nil,
      limit_amount_min: nil, limit_amount_max: nil, in_progress_count_limit: nil,
      in_progress_count: nil, in_progress_amount_limit: nil, in_progress_amount: nil,
      available_requisites: nil, avg_latency_sec: 30, banks: nil, exclude_banks: nil,
      provider_margin_pct: nil, merchant_margin_pct: nil, allow_negative_agreement: nil,
      requests_per_minute_limit: nil, daily_turnover_min: nil, daily_turnover_max: nil,
      **attrs
    )
  end

  def build_attempt(raw)
    Routing::Attempt.new(**raw.transform_keys(&:to_sym))
  end

  def build_operation(id, amount)
    Domain::Operation.new(operation_id: id, created_at: '2026-07-30T10:00:00+03:00',
                          amount: amount, bank: 'sberbank', card_brand: nil,
                          payout_requisite: 'req')
  end

  let(:vipay) do
    build_provider('vipay', traffic_percentage: 40, volume_share_pct: 50,
                            daily_amount_limit: 5_000_000, daily_approved_amount: 3_200_000,
                            conversion_24h: 0.87)
  end
  let(:payflow) do
    build_provider('payflow', traffic_percentage: 35, volume_share_pct: 25,
                              daily_amount_limit: 3_000_000, daily_approved_amount: 2_900_000,
                              conversion_24h: 0.91)
  end
  let(:quickpay) do
    build_provider('quickpay', traffic_percentage: 25, volume_share_pct: 25,
                               daily_amount_limit: 8_000_000, daily_approved_amount: 1_100_000,
                               conversion_24h: 0.79)
  end
  let(:spacepayments) do
    build_provider('spacepayments', traffic_percentage: 0, volume_share_pct: 0,
                                    daily_amount_limit: nil, daily_approved_amount: 0,
                                    conversion_24h: 0.95)
  end
  let(:providers) { [vipay, payflow, quickpay, spacepayments] }
  let(:history) { { 'vipay' => 0.780, 'payflow' => 0.474, 'quickpay' => 0.675 } }

  # op_a: одобрен с первой реальной попытки.
  let(:op_a) { build_operation('op_a', 50_000) }
  let(:outcome_a) do
    attempts = [
      build_attempt('provider' => 'vipay', 'decision' => 'selected',
                    'reason' => 'first_eligible', 'attempt_no' => 1, 'result' => 'approved')
    ]
    Execution::Outcome.new(selected: vipay, attempts: attempts, result: :approved)
  end

  # op_b: payflow отклонён, каскад восстанавливается на quickpay.
  let(:op_b) { build_operation('op_b', 100_000) }
  let(:outcome_b) do
    attempts = [
      build_attempt('provider' => 'payflow', 'decision' => 'selected',
                    'reason' => 'first_eligible', 'attempt_no' => 1, 'result' => 'rejected'),
      build_attempt('provider' => 'quickpay', 'decision' => 'selected',
                    'reason' => 'next_in_cascade', 'attempt_no' => 2, 'result' => 'approved')
    ]
    Execution::Outcome.new(selected: quickpay, attempts: attempts, result: :approved)
  end

  # op_c: ни один реальный провайдер не допущен -> fallback в spacepayments.
  let(:op_c) { build_operation('op_c', 20_000) }
  let(:outcome_c) do
    attempts = [
      build_attempt('provider' => 'vipay', 'decision' => 'skipped',
                    'reason' => 'bank_not_in_list', 'details' => 'raiffeisen not in list'),
      build_attempt('provider' => 'payflow', 'decision' => 'skipped',
                    'reason' => 'bank_not_in_list', 'details' => 'raiffeisen not in list'),
      build_attempt('provider' => 'quickpay', 'decision' => 'skipped',
                    'reason' => 'bank_not_in_list', 'details' => 'raiffeisen not in list'),
      build_attempt('provider' => 'spacepayments', 'decision' => 'selected',
                    'reason' => 'fallback_no_eligible_provider', 'attempt_no' => 1,
                    'result' => 'approved')
    ]
    Execution::Outcome.new(selected: spacepayments, attempts: attempts, result: :approved)
  end

  let(:pairs) { [[op_a, outcome_a], [op_b, outcome_b], [op_c, outcome_c]] }
  let(:report) do
    described_class.build(pairs, providers: providers, history: history)
  end

  describe '.build' do
    it 'считает period и total_operations' do
      expect(report['period']).to eq('2026-07-30')
      expect(report['total_operations']).to eq(3)
    end

    # achievable_pct здесь 0.0 у всех внешних: синтетический снапшот фикстуры
    # никого не допускает до этих трёх операций, значит достижимая доля и есть
    # ноль. Настоящие числа публичной очереди проверяет спек ниже.
    it 'считает distribution по итоговому selected_provider' do
      expect(report['distribution']).to eq(
        'vipay' => { 'count' => 1, 'share_pct' => 33.3, 'target_pct' => 40,
                     'achievable_pct' => 0.0, 'deviation_pp' => 33.3 },
        'payflow' => { 'count' => 0, 'share_pct' => 0.0, 'target_pct' => 35,
                       'achievable_pct' => 0.0, 'deviation_pp' => 0.0 },
        'quickpay' => { 'count' => 1, 'share_pct' => 33.3, 'target_pct' => 25,
                        'achievable_pct' => 0.0, 'deviation_pp' => 33.3 },
        'spacepayments' => { 'count' => 1, 'share_pct' => 33.3, 'target_pct' => 0,
                             'achievable_pct' => nil, 'deviation_pp' => 33.3 }
      )
    end

    it 'считает volume_distribution по сумме заявок итогового provider' do
      expect(report['volume_distribution']['payflow']).to eq(
        'amount' => 0, 'share_pct' => 0.0, 'target_pct' => 25,
        'achievable_pct' => nil, 'deviation_pp' => -25.0
      )
      expect(report['volume_distribution']['quickpay']).to eq(
        'amount' => 100_000, 'share_pct' => 58.8, 'target_pct' => 25,
        'achievable_pct' => nil, 'deviation_pp' => 33.8
      )
    end

    it 'считает attempt_distribution только по реальным попыткам (decision selected)' do
      expect(report['attempt_distribution']).to eq(
        'vipay' => { 'attempts' => 1, 'successful' => 1, 'observed_conversion' => 1.0 },
        'payflow' => { 'attempts' => 1, 'successful' => 0, 'observed_conversion' => 0.0 },
        'quickpay' => { 'attempts' => 1, 'successful' => 1, 'observed_conversion' => 1.0 },
        'spacepayments' => { 'attempts' => 1, 'successful' => 1, 'observed_conversion' => 1.0 }
      )
    end

    it 'агрегирует skip_reasons по причинам эл. отсева' do
      expect(report['skip_reasons']).to eq('bank_not_in_list' => 3)
    end

    it 'проецирует дневной лимит: снимок + одобренное в партии' do
      expect(report['projected_daily_utilization']).to eq(
        'vipay' => { 'used' => 3_250_000, 'limit' => 5_000_000, 'utilization_pct' => 65.0 },
        'payflow' => { 'used' => 2_900_000, 'limit' => 3_000_000, 'utilization_pct' => 96.7 },
        'quickpay' => { 'used' => 1_200_000, 'limit' => 8_000_000, 'utilization_pct' => 15.0 },
        'spacepayments' => { 'used' => 20_000, 'limit' => nil, 'utilization_pct' => nil }
      )
    end

    it 'считает fallback-метрики: первая попытка, восстановление каскадом, spacepayments' do
      expect(report['fallback']).to eq(
        'first_attempt_success' => 2, 'recovered_by_fallback' => 1,
        'fallback_rate_pct' => 33.3, 'spacepayments_used' => 1, 'cascade_exhausted' => 0
      )
    end

    it 'заводит benchmark в замороженной форме' do
      expect(report['benchmark']).to eq(
        'offline_bound' => nil, 'our_online_result' => nil,
        'competitive_ratio' => nil, 'note' => 'эталон не считался'
      )
      expect(report['deviation_causes']).to eq([])
    end

    it 'передаёт benchmark без изменений' do
      benchmark = { 'offline_bound' => { 'max_deviation_pp' => 5.0, 'delivered' => 10 } }

      expect(described_class.build(pairs, providers: providers, benchmark: benchmark)['benchmark'])
        .to equal(benchmark)
    end

    it 'формирует параметрические recommendations по конверсии и дневному лимиту' do
      expect(report['recommendations']).to contain_exactly(
        'vipay: conversion_24h заявлена 0.87, наблюдаемая 0.78 по истории — ' \
        'пересчитать по факту',
        'payflow: conversion_24h заявлена 0.91, наблюдаемая 0.474 по истории — ' \
        'пересчитать по факту',
        'payflow: свободно 100 000 ₽ при среднем чеке 56 667 ₽ — ' \
        'снизить traffic_percentage 35 → 20 до сброса дневного лимита',
        'quickpay: conversion_24h заявлена 0.79, наблюдаемая 0.675 по истории — ' \
        'пересчитать по факту'
      )
    end
  end

  describe '.write' do
    it 'пишет JSON с завершающим переводом строки и без экранирования кириллицы' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'routing_report_test.json')

        described_class.write(path, pairs, providers: providers, history: history)
        content = File.read(path)

        expect(content).to end_with("\n")
        expect(content).to include('пересчитать по факту')
        expect(JSON.parse(content)['total_operations']).to eq(3)
      end
    end

    it 'даёт побайтово одинаковый результат на двух записях подряд' do
      Dir.mktmpdir do |dir|
        path_a = File.join(dir, 'a.json')
        path_b = File.join(dir, 'b.json')

        described_class.write(path_a, pairs, providers: providers, history: history)
        described_class.write(path_b, pairs, providers: providers, history: history)

        expect(File.binread(path_a)).to eq(File.binread(path_b))
      end
    end
  end
end
# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers
