# frozen_string_literal: true

require 'json'
require 'tmpdir'
require 'reporting/report_builder'
require 'domain/operation'
require 'domain/provider'
require 'routing/attempt'
require 'execution/outcome'
require 'io/history_stats'

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
  let(:history) do
    Io::HistoryStats.new(
      entries: {
        'vipay' => history_entry(obs: 1000, approved: 780),
        'payflow' => history_entry(obs: 1000, approved: 474),
        'quickpay' => history_entry(obs: 1000, approved: 675)
      },
      k: 0, smoothed: false
    )
  end
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

  # n=1000 у всех троих намеренно: это выше Recommendations::LARGE_SAMPLE_N
  # (200), так что verdict остаётся "пересчитать по факту" -- фикстура
  # проверяет форму сообщения (число наблюдений видно), а не порог малой
  # выборки, у него отдельный спек в spec/reporting/recommendations_spec.rb.
  def history_entry(obs:, approved:)
    approved_bp = (approved * 10_000) / obs
    Io::HistoryStats::Entry.new(
      n: obs, approved_count: approved, rejected_count: 0, expired_count: obs - approved,
      approved_bp: approved_bp, rejected_bp: 0, expired_bp: 10_000 - approved_bp
    )
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

    # achievable_pct здесь 0.0 у всех внешних той же причине, что и у
    # distribution по количеству (см. комментарий выше): синтетический
    # снапшот никого не допускает, достижимая доля по объёму вырождается в
    # ноль, и deviation_pp меряется от неё, а не от паспортной target_pct.
    it 'считает volume_distribution по сумме заявок итогового provider' do
      expect(report['volume_distribution']['payflow']).to eq(
        'amount' => 0, 'share_pct' => 0.0, 'target_pct' => 25,
        'achievable_pct' => 0.0, 'deviation_pp' => 0.0
      )
      expect(report['volume_distribution']['quickpay']).to eq(
        'amount' => 100_000, 'share_pct' => 58.8, 'target_pct' => 25,
        'achievable_pct' => 0.0, 'deviation_pp' => 58.8
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
    end

    it 'передаёт benchmark без изменений' do
      benchmark = { 'offline_bound' => { 'max_deviation_pp' => 5.0, 'delivered' => 10 } }

      expect(described_class.build(pairs, providers: providers, benchmark: benchmark)['benchmark'])
        .to equal(benchmark)
    end

    # comparison приходит готовым kwarg-ом, как benchmark -- build его не
    # считает и не трогает.
    it 'без kwarg-а comparison ключа `comparison` в отчёте нет вовсе' do
      expect(report).not_to have_key('comparison')
    end

    it 'с kwarg-ом comparison ключ на месте и передаётся без изменений' do
      comparison = { 'baseline' => 'count_share', 'variants' => {}, 'note' => 'тест' }

      result = described_class.build(pairs, providers: providers, history: history,
                                            comparison: comparison)

      expect(result['comparison']).to equal(comparison)
    end

    # pending_resolution приходит готовым kwarg-ом из bin/route
    # (Reporting::PendingResolutionSummary.build), как comparison/benchmark --
    # build его не считает и не трогает.
    it 'без kwarg-а pending_resolution ключа `pending_resolution` в отчёте нет вовсе' do
      expect(report).not_to have_key('pending_resolution')
    end

    it 'с kwarg-ом pending_resolution ключ на месте и передаётся без изменений' do
      pending_resolution = { 'checked' => 1, 'resolved' => 1, 'approved' => 1, 'rejected' => 0,
                             'still_pending' => 0 }

      result = described_class.build(pairs, providers: providers, history: history,
                                            pending_resolution: pending_resolution)

      expect(result['pending_resolution']).to equal(pending_resolution)
    end

    # Синтетический снапшот фикстуры не допускает НИКОГО ни до одной из трёх
    # операций (см. комментарий у теста distribution выше) -- Achievable не
    # может приписать отклонение ни допуску (:only_option), ни дневному
    # лимиту (:money), bound уходит в :none. DeviationCauses в этом случае не
    # молчит и не гадает, а помечает причину как неопределённую -- реальные
    # структурные случаи (:only_option/:money) проверяет
    # spec/reporting/deviation_causes_spec.rb
    # на настоящих данных публичной очереди. Причины по объёму ("по объёму" в
    # тексте) идут тем же путём и по той же причине -- их втрое больше на
    # том же вырожденном снапшоте, а не на другом наборе провайдеров.
    it 'помечает отклонение без структурной причины как требующее ручного разбора' do
      expect(report['deviation_causes']).to contain_exactly(
        a_string_matching(/\Avipay -6\.7 п\.п\. к цели: структурная причина не определена/),
        a_string_matching(/\Apayflow -35 п\.п\. к цели: структурная причина не определена/),
        a_string_matching(/\Aquickpay \+8\.3 п\.п\. к цели: структурная причина не определена/),
        a_string_matching(/\Avipay -20\.6 п\.п\. по объёму: структурная причина не определена/),
        a_string_matching(/\Apayflow -25 п\.п\. по объёму: структурная причина не определена/),
        a_string_matching(/\Aquickpay \+33\.8 п\.п\. по объёму: структурная причина не определена/)
      )
    end

    # Тот же вырожденный снапшот делает achievable_bp равным нулю (округлённо)
    # у всех провайдеров -- Retarget сознательно НЕ предлагает "снизить цели до
    # 0%" без структурной причины (reason_for пуст, все bound == :none), иначе
    # рекомендация звучала бы как пустое "недостижимы () -- снизьте всё до
    # нуля". Реальный retarget с непустой причиной проверяет тест ниже и
    # spec/reporting/retarget_spec.rb.
    it 'не предлагает retarget, когда недостижимость не объяснена структурно' do
      expect(report['recommendations']).not_to include(a_string_starting_with('retarget:'))
    end

    it 'формирует параметрические recommendations по конверсии и дневному лимиту' do
      expect(report['recommendations']).to contain_exactly(
        'vipay: conversion_24h заявлена 0.87, по истории 780/1000 (наблюдаемая 0.78) — ' \
        'пересчитать по факту',
        'payflow: conversion_24h заявлена 0.91, по истории 474/1000 (наблюдаемая 0.474) — ' \
        'пересчитать по факту',
        'payflow: свободно 100 000 ₽ при среднем чеке 56 667 ₽ — ' \
        'снизить traffic_percentage 35 → 20 до сброса дневного лимита',
        'quickpay: conversion_24h заявлена 0.79, по истории 675/1000 (наблюдаемая 0.675) — ' \
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
