# frozen_string_literal: true

require 'routing/planner'
require 'routing/layer_stack'
require 'routing/share_ledger'
require 'state/providers'
require 'execution/executor'
require 'execution/outcome_source/always_ok'

# Билдер сценария-ловушки бюджета для слоя ψ.
# Безотносителен к конкретному слою: принимает произвольный
# Routing::LayerStack (по умолчанию пустой), сам не знает о ψ — только строит
# providers/operations и прогоняет их через реальный
# Planner+Executor+State::Providers — ровно как build_pipeline в bin/route
# (#plan получает тот же State::Providers, что и #run у Executor, а не голый
# ShareLedger — иначе слой, читающий live daily_approved_amount, не увидел бы
# рост бюджета между op_a и op_b и молча откатился на замороженный снапшот).
#
# ВАЖНО, уточнено проверкой запуском кода (не только чтением плана):
# `Constraints::DailyLimit.approved_amount` уже читает живое
# `state.daily_approved_amount(name)`, когда `state` его поддерживает
# (lib/routing/constraints/daily_limit.rb) — то есть "архитектурный факт",
# что "хард-констрейнт не видит рост бюджета за прогон", был верен на момент
# планирования, но уже устранён в коде (см. commit 8ce1d96, раньше слоя
# budget_headroom).
# Буквальная "ловушка" — операция, индивидуально одобренная, но суммарно
# пробивающая лимит провайдера, — поэтому сегодня НЕ воспроизводится
# вообще, ни с ψ, ни без: DailyLimit сам ловит вторую операцию (op_b) и не
# даёт payflow превысить лимит (см. `bin/route:208`, `pipeline[:state]`
# передаётся в `plan`, а не в `pipeline[:ledger]`; здесь то же самое).
#
# Что этот сценарий демонстрирует вместо буквальной "ловушки" — реальную
# разницу между двумя способами не превысить лимит:
#   БЕЗ ψ: payflow отдаётся жадно, пока дневной лимит не остановит его сам —
#     op_a уходит в payflow, op_b получает от payflow "skipped
#     (daily_limit_exceeded)" и падает на следующего кандидата (vipay).
#     payflow довели до упора (96 000 из 100 000), обошлось только потому, что
#     хард-констрейнт успел вмешаться в последний момент.
#   С ψ: budget_headroom видит падающий психологический запас payflow раньше,
#     чем сработал бы хард-лимит, и перестаёт выбирать payflow, пока запас не
#     восстановится — payflow вообще не участвует в каскаде ни для одной из
#     операций, daily_approved_amount остаётся на стартовых 90 000.
# payflow: лимит 100 000 ₽, из них 90 000 ₽ уже одобрено (снапшот на старт
# прогона). Две операции по 6 000 ₽ дают ровно тот запас (T: 0.90 → 0.96),
# на котором граница ψ (см. psi_trap_scenario_spec.rb) наглядно расходится с
# границой хард-констрейнта.
module PsiTrapScenario
  module_function

  def providers
    [payflow, vipay, spacepayments]
  end

  def payflow
    ProviderFactory.build_provider(
      payment_system: 'payflow', priority: 1,
      daily_amount_limit: 100_000, daily_approved_amount: 90_000,
      limit_amount_min: 500, limit_amount_max: 50_000
    )
  end

  def vipay
    ProviderFactory.build_provider(
      payment_system: 'vipay', priority: 2,
      daily_amount_limit: 1_000_000, daily_approved_amount: 0,
      limit_amount_min: 500, limit_amount_max: 50_000
    )
  end

  def spacepayments
    ProviderFactory.build_provider(
      payment_system: 'spacepayments', priority: 99, traffic_percentage: 0,
      daily_amount_limit: nil, daily_approved_amount: 0,
      limit_amount_min: nil, limit_amount_max: nil, banks: []
    )
  end

  def operations
    [
      ProviderFactory.build_operation(operation_id: 'op_a', amount: 6_000),
      ProviderFactory.build_operation(operation_id: 'op_b', amount: 6_000)
    ]
  end

  # Прогоняет обе операции подряд по одному State::Providers.
  # strategy — любой Routing::Strategies::Base. layers — Routing::LayerStack,
  # по умолчанию пустой ("прогон без ψ"); передайте стопку с budget_headroom,
  # чтобы получить "прогон с ψ".
  def run(strategy:, layers: Routing::LayerStack.new([]))
    snapshot = providers
    pipeline = build_pipeline(snapshot, strategy, layers)

    outcomes = operations.each_with_object({}) do |operation, acc|
      plan = pipeline.fetch(:planner).plan(operation, pipeline.fetch(:state))
      acc[operation.operation_id] =
        pipeline.fetch(:executor).run(plan, operation, pipeline.fetch(:state))
    end

    result_for(pipeline.fetch(:state), outcomes)
  end

  def build_pipeline(snapshot, strategy, layers = Routing::LayerStack.new([]))
    state = State::Providers.new(snapshot)
    {
      planner: Routing::Planner.new(providers: snapshot, strategy: strategy, layers: layers),
      executor: Execution::Executor.new(outcomes: Execution::OutcomeSource::AlwaysOk.new),
      state: state,
      ledger: state.shares
    }
  end

  # payflow_real_total читается напрямую из живого State::Providers
  # (daily_approved_amount растёт на #commit) — та же величина, которую видят
  # и DailyLimit, и ψ-слой; без ψ она дорастает до упора (но не выше лимита),
  # с ψ остаётся на стартовом уровне.
  def result_for(state, outcomes)
    payflow = providers.find { |p| p.name == 'payflow' }
    {
      outcomes: outcomes,
      payflow_real_total: state.daily_approved_amount('payflow'),
      payflow_real_limit: payflow.daily_amount_limit
    }
  end
end
