# frozen_string_literal: true

require 'routing/route_plan'
require 'state/providers'
require 'execution/executor'
require 'execution/pending_resolution_pass'

# Доказательство того, что решает пакет (см. бриф "подключить PendingResolver
# вторым проходом"): на длинной очереди с накопленными таймаутами один
# провайдер копит held-резервы без ограничения -- State::Providers#hold не
# освобождает ёмкость, только resolve_hold освобождает её, а до этого пакета
# resolve_hold никто не звал. Без второго прохода in_progress_count провайдера
# растёт линейно с числом таймаутов и никогда не возвращается; со вторым --
# возвращается к 0 (все held-резервы либо approved, либо rejected, оба
# закрывают резерв).
#
# attempt_no > 0 -- исходная (первая) попытка кассада, всегда :expired --
# реалистичная деградация провайдера с высокой долей таймаутов (по истории
# quickpay -- 15.2%, payflow -- 29.0%; здесь взят крайний случай 100% для
# наглядности накопления). attempt_no < 0 -- поздний статус-чек
# (Execution::PendingResolutionPass кодирует его как -attempt_no исходной
# попытки, см. класс-комментарий) -- всегда даёт настоящий ответ, чётность
# operation_id решает approved/rejected, чтобы проверить, что daily_approved
# растёт только на approved-половине.
class LongQueueOutcomeSource
  def call(operation, _provider, attempt_no)
    return :expired if attempt_no.positive?

    even_id?(operation) ? :approved : :rejected
  end

  def even_id?(operation)
    operation.operation_id[/\d+/].to_i.even?
  end
end

# rubocop:disable RSpec/DescribeClass -- описывает поведение пары
# Executor+PendingResolutionPass на сценарии, а не один класс.
# rubocop:disable RSpec/MultipleMemoizedHelpers, RSpec/MultipleExpectations, RSpec/ExampleLength
# -- сценарий на длинной очереди: подготовка (провайдеры/очередь/executor) и
# проверка нескольких срезов состояния после одного прогона естественно не
# укладываются в дефолтные лимиты пяти let/строк/expectations.
RSpec.describe 'Execution::PendingResolutionPass на длинной очереди' do
  let(:quickpay) do
    build_provider('quickpay', traffic_percentage: 25, banks: [], available_requisites: 999)
  end
  let(:spacepayments) { build_spacepayments }
  let(:providers) { [quickpay, spacepayments] }
  let(:state) { State::Providers.new(providers) }
  let(:outcomes) { LongQueueOutcomeSource.new }
  let(:executor) { Execution::Executor.new(outcomes: outcomes) }
  let(:queue_size) { 200 }

  let(:operations) do
    (1..queue_size).map { |i| build_operation(id: "op_#{i}", amount: 1_000) }
  end
  let(:pairs) do
    operations.map { |operation| [operation, executor.run(plan_for(operation), operation, state)] }
  end

  # Один-единственный кандидат -- quickpay -- на каждую операцию: тест бьёт
  # именно про накопление held-резервов Executor+State, эл. допуск (Planner/
  # Constraints) уже проверен отдельно в spec/routing.
  def plan_for(operation)
    Routing::RoutePlan.new(operation: operation, candidates: [quickpay], skipped: [])
  end

  it 'без второго прохода ёмкость провайдера проседает на всю очередь таймаутов' do
    pairs

    expect(state.in_progress_count('quickpay')).to eq(queue_size)
    expect(pairs.map { |_operation, outcome| outcome.result }).to all(eq(:expired))
  end

  it 'со вторым проходом ёмкость полностью восстанавливается' do
    pairs # первый проход: все 200 held

    approved_amount = operations.count { |op| op.operation_id[/\d+/].to_i.even? } * 1_000

    report = Execution::PendingResolutionPass.new(outcomes: outcomes, providers: providers)
                                             .call(pairs, state)

    expect(state.in_progress_count('quickpay')).to eq(0)
    expect(state.daily_approved_amount('quickpay')).to eq(approved_amount)
    expect(report.checked).to eq(queue_size)
    expect(report.still_pending).to be_empty
    expect(report.resolved).to eq(queue_size)
  end

  it 'rejected-половина освобождает резерв, но не растит daily_approved_amount' do
    pairs
    Execution::PendingResolutionPass.new(outcomes: outcomes, providers: providers).call(pairs,
                                                                                        state)

    rejected_amount = operations.count { |op| op.operation_id[/\d+/].to_i.odd? } * 1_000
    total_amount = queue_size * 1_000

    expect(state.daily_approved_amount('quickpay')).to eq(total_amount - rejected_amount)
  end
end
# rubocop:enable RSpec/DescribeClass
# rubocop:enable RSpec/MultipleMemoizedHelpers, RSpec/MultipleExpectations, RSpec/ExampleLength
