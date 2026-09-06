# frozen_string_literal: true

require 'routing/planner'
require 'routing/reasons'
require 'execution/executor'
require 'execution/outcome_source/base'
require 'state/providers'
require_relative '../support/provider_factory'

# Живая проверка in_progress/available_requisites, включённая этим пакетом:
# раньше Planner видел только статический снимок (in_progress_count из
# providers.json), поэтому резервы, поставленные на предыдущих заявках ЭТОЙ
# ЖЕ очереди, планировщику были не видны — на 2000 операциях бенчмарка из
# брифа это дало 624 таймаута и ни одного отсева in_progress_limit_exceeded.
# Три сценария ниже гоняют настоящий Planner + Executor + State::Providers,
# а не проверяют State или Constraints по отдельности.
RSpec.describe 'живая проверка ёмкости провайдера в пайплайне' do
  include ProviderFactory

  # Вырожденный источник: любая попытка — таймаут. Кроме AlwaysOk/AlwaysFail
  # в lib/execution/outcome_source больше готовых вырожденных случаев нет, а
  # заводить AlwaysExpired в lib/ ради одного спека — лишняя сущность в
  # боевом коде (правило "не трогай lib/execution/pending_resolver.rb" сюда
  # же: холд не разбирается, expired должен НАКАПЛИВАТЬСЯ, а не сниматься).
  let(:always_expired) do
    Class.new(Execution::OutcomeSource::Base) do
      def call(*) = :expired
    end.new
  end

  # Ограничений, кроме in_progress_count_limit, у target нет: банк, сумма,
  # маржа и дневной лимит намеренно сняты, чтобы отсев в тесте объяснялся
  # только ёмкостью, а не случайно сработавшей соседней проверкой.
  let(:target) do
    build_provider(payment_system: 'vipay', in_progress_count_limit: 2, in_progress_count: 0,
                   in_progress_amount_limit: nil, daily_amount_limit: nil, banks: [])
  end
  let(:alternate) do
    build_provider(payment_system: 'payflow', in_progress_count_limit: nil,
                   in_progress_amount_limit: nil, daily_amount_limit: nil, banks: [])
  end
  let(:fallback) { build_provider(payment_system: 'spacepayments') }

  # Прогоняет через Planner+Executor столько операций, сколько нужно, чтобы
  # держащиеся (expired) резервы target добили in_progress_count_limit.
  # providers здесь — только [target, fallback]: без альтернативы target
  # остаётся единственным внешним кандидатом и гарантированно получает
  # каждую заявку, поэтому холды накапливаются предсказуемо, без гонки со
  # стратегией ранжирования.
  def accumulate_holds!(state)
    planner = Routing::Planner.new(providers: [target, fallback])
    executor = Execution::Executor.new(outcomes: always_expired)

    target.in_progress_count_limit.times do |i|
      operation = build_operation(operation_id: "op_hold_#{i}")
      plan = planner.plan(operation, state)
      executor.run(plan, operation, state)
    end
  end

  it 'накопленные холды таймаутов реально уменьшают доступную ёмкость' do
    state = State::Providers.new([target, fallback])

    expect { accumulate_holds!(state) }
      .to change { state.in_progress_count('vipay') }.from(0).to(target.in_progress_count_limit)
  end

  # rubocop:disable-next RSpec/ExampleLength, RSpec/MultipleExpectations -- решающий путь целиком.
  it 'отсекает провайдера на пределе ёмкости, когда есть другой кандидат' do
    state = State::Providers.new([target, alternate, fallback])
    accumulate_holds!(state)

    plan = Routing::Planner.new(providers: [target, alternate, fallback])
                           .plan(build_operation(operation_id: 'op_final'), state)

    expect(plan.candidates.map(&:name)).to eq(['payflow'])
    skip_reasons = plan.skipped.to_h { |provider, violation| [provider.name, violation.reason] }
    expect(skip_reasons.fetch('vipay')).to eq('in_progress_limit_exceeded')
    expect(Routing::Reasons::SKIP).to include(skip_reasons.fetch('vipay'))
  end

  # rubocop:disable-next RSpec/ExampleLength, RSpec/MultipleExpectations -- план, trace и причина.
  it 'смягчает отсев, когда живая проверка опустошила бы весь пул' do
    state = State::Providers.new([target, fallback])
    accumulate_holds!(state)

    plan = Routing::Planner.new(providers: [target, fallback])
                           .plan(build_operation(operation_id: 'op_final'), state)

    expect(plan.candidates.map(&:name)).to eq(['vipay'])
    expect(plan.skipped).to be_empty
    expect(plan.trace.details).to include('ограничение не применено')
    expect(plan.trace.details).to include('in_progress')
  end
end
