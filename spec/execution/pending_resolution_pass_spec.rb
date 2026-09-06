# frozen_string_literal: true

require 'execution/pending_resolution_pass'
require 'state/providers'
require 'routing/attempt'
require 'execution/outcome'

# Тестовый источник исходов: не хеш от seed (это Deterministic, у него свой
# спек), а явная таблица ответов по (operation_id, provider, attempt_no) —
# так видно ровно то, какой attempt_no пришёл на поздний статус-чек, без
# необходимости подбирать seed под нужный SHA256-roll.
class RecordingOutcomeSource
  attr_reader :calls

  def initialize(responses)
    @responses = responses
    @calls = []
  end

  def call(operation, provider, attempt_no)
    @calls << [operation.operation_id, provider.name, attempt_no]
    @responses.fetch([operation.operation_id, provider.name, attempt_no]) do
      raise KeyError, "нет заготовленного ответа для #{[operation.operation_id, provider.name,
                                                        attempt_no]}"
    end
  end
end

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength -- каждый сценарий проверяет
# триплет (Report, State, pairs-неприкосновенность) одного вызова #call.
# rubocop:disable RSpec/MultipleMemoizedHelpers -- четыре именованных провайдера
# (vipay/payflow/quickpay/spacepayments) читаемее безымянного массива.
RSpec.describe Execution::PendingResolutionPass do
  let(:vipay) do
    build_provider('vipay', traffic_percentage: 40, in_progress_count: 4,
                            in_progress_amount: 380_000, daily_approved_amount: 3_200_000,
                            available_requisites: 12)
  end
  let(:payflow) { build_provider('payflow', traffic_percentage: 35) }
  let(:quickpay) { build_provider('quickpay', traffic_percentage: 25) }
  let(:spacepayments) { build_spacepayments }
  let(:providers) { [vipay, payflow, quickpay, spacepayments] }
  let(:state) { State::Providers.new(providers) }

  def expired_attempt(provider_name, attempt_no)
    Routing::Attempt.new(provider: provider_name, decision: 'selected', reason: 'first_eligible',
                         attempt_no: attempt_no, result: 'expired')
  end

  def build_pass(outcomes)
    described_class.new(outcomes: outcomes, providers: providers)
  end

  # Держит резерв как это делает Execution::Executor на первом проходе:
  # reserve (списывает ёмкость), затем hold (переносит его в held, ёмкость
  # остаётся списанной до resolve_hold).
  def hold!(provider, operation)
    state.reserve(provider, operation)
    state.hold(provider, operation)
  end

  describe '#call' do
    it 'approved на позднем статус-чеке освобождает held-резерв и растит daily_approved' do
      operation = build_operation(id: 'op_101', amount: 10_000)
      outcome = Execution::Outcome.new(selected: vipay, attempts: [expired_attempt('vipay', 1)],
                                       result: :expired)
      hold!(vipay, operation)
      outcomes = RecordingOutcomeSource.new([operation.operation_id, 'vipay', -1] => :approved)

      report = build_pass(outcomes).call([[operation, outcome]], state)

      expect(state.in_progress_count('vipay')).to eq(4)
      expect(state.daily_approved_amount('vipay')).to eq(3_210_000)
      expect(report.checked).to eq(1)
      expect(report.resolved).to eq(1)
      expect(report.approved_count).to eq(1)
      expect(report.rejected_count).to eq(0)
      expect(report.still_pending).to be_empty
      expect(report.freed_amount).to eq(10_000)
    end

    it 'rejected на позднем статус-чеке освобождает held-резерв, daily_approved не трогает' do
      operation = build_operation(id: 'op_102', amount: 7_000)
      outcome = Execution::Outcome.new(selected: payflow, attempts: [expired_attempt('payflow', 1)],
                                       result: :expired)
      hold!(payflow, operation)
      outcomes = RecordingOutcomeSource.new([operation.operation_id, 'payflow', -1] => :rejected)

      report = build_pass(outcomes).call([[operation, outcome]], state)

      expect(state.in_progress_count('payflow')).to eq(0)
      expect(state.daily_approved_amount('payflow')).to eq(0)
      expect(report.approved_count).to eq(0)
      expect(report.rejected_count).to eq(1)
      expect(report.still_pending).to be_empty
    end

    it ':expired на позднем статус-чеке оставляет резерв held (still_pending, без ArgumentError)' do
      operation = build_operation(id: 'op_103', amount: 5_000)
      outcome = Execution::Outcome.new(
        selected: quickpay, attempts: [expired_attempt('quickpay', 1)], result: :expired
      )
      hold!(quickpay, operation)
      outcomes = RecordingOutcomeSource.new([operation.operation_id, 'quickpay', -1] => :expired)

      report = nil
      expect { report = build_pass(outcomes).call([[operation, outcome]], state) }
        .not_to raise_error

      # held-резерв не освобождён -- ёмкость остаётся списанной ровно как
      # после первого прохода (reserve + hold), a не восстановлена до 0.
      expect(state.in_progress_count('quickpay')).to eq(1)
      expect(report.checked).to eq(1)
      expect(report.resolved).to eq(0)
      expect(report.still_pending.size).to eq(1)
      expect(report.still_pending.first.actual).to eq(:expired)
    end

    it 'кодирует attempt_no позднего статус-чека как -attempt_no исходной попытки' do
      operation = build_operation(id: 'op_104', amount: 1_000)
      outcome = Execution::Outcome.new(
        selected: quickpay, attempts: [expired_attempt('quickpay', 2)], result: :approved
      )
      hold!(quickpay, operation)
      outcomes = RecordingOutcomeSource.new([operation.operation_id, 'quickpay', -2] => :approved)

      build_pass(outcomes).call([[operation, outcome]], state)

      expect(outcomes.calls).to eq([[operation.operation_id, 'quickpay', -2]])
    end

    it 'не зовёт источник исходов для операций без expired-попыток' do
      operation = build_operation(id: 'op_105', amount: 2_000)
      outcome = Execution::Outcome.new(
        selected: vipay,
        attempts: [Routing::Attempt.new(provider: 'vipay', decision: 'selected',
                                        reason: 'first_eligible', attempt_no: 1,
                                        result: 'approved')],
        result: :approved
      )
      outcomes = RecordingOutcomeSource.new({})

      report = build_pass(outcomes).call([[operation, outcome]], state)

      expect(outcomes.calls).to be_empty
      expect(report.checked).to eq(0)
    end

    it 'разрешает несколько held-резервов из разных операций независимо' do
      op_a = build_operation(id: 'op_106', amount: 3_000)
      op_b = build_operation(id: 'op_107', amount: 4_000)
      outcome_a = Execution::Outcome.new(selected: vipay, attempts: [expired_attempt('vipay', 1)],
                                         result: :expired)
      outcome_b = Execution::Outcome.new(
        selected: payflow, attempts: [expired_attempt('payflow', 1)], result: :expired
      )
      hold!(vipay, op_a)
      hold!(payflow, op_b)
      outcomes = RecordingOutcomeSource.new(
        [op_a.operation_id, 'vipay', -1] => :approved,
        [op_b.operation_id, 'payflow', -1] => :rejected
      )

      report = build_pass(outcomes).call([[op_a, outcome_a], [op_b, outcome_b]], state)

      expect(report.resolved).to eq(2)
      expect(report.approved_count).to eq(1)
      expect(report.rejected_count).to eq(1)
      expect(state.in_progress_count('vipay')).to eq(4)
      expect(state.in_progress_count('payflow')).to eq(0)
    end

    # Held-резерв может остаться и у НЕ-финального провайдера каскада
    # (on_timeout: :continue): outcome.result уже :approved у следующего
    # кандидата, но таймаут-провайдер из более ранней попытки всё равно
    # остался held (см. класс-комментарий и инвариант #2 в
    # spec/support/shared_state_invariants.rb) -- второй проход обязан найти
    # его тоже, а не только held у итогового selected.
    it 'находит held-резерв не только у финального selected, но и у промежуточного' do
      operation = build_operation(id: 'op_108', amount: 6_000)
      attempts = [
        expired_attempt('payflow', 1),
        Routing::Attempt.new(provider: 'quickpay', decision: 'selected', reason: 'next_in_cascade',
                             attempt_no: 2, result: 'approved')
      ]
      outcome = Execution::Outcome.new(selected: quickpay, attempts: attempts, result: :approved)
      hold!(payflow, operation)
      state.reserve(quickpay, operation)
      state.commit(quickpay, operation)
      outcomes = RecordingOutcomeSource.new([operation.operation_id, 'payflow', -1] => :rejected)

      report = build_pass(outcomes).call([[operation, outcome]], state)

      expect(report.resolved).to eq(1)
      expect(state.in_progress_count('payflow')).to eq(0)
    end

    it 'не переписывает pairs -- attempts и simulated-исход остаются прежними' do
      operation = build_operation(id: 'op_109', amount: 8_000)
      outcome = Execution::Outcome.new(selected: vipay, attempts: [expired_attempt('vipay', 1)],
                                       result: :expired)
      hold!(vipay, operation)
      outcomes = RecordingOutcomeSource.new([operation.operation_id, 'vipay', -1] => :approved)
      pairs = [[operation, outcome]]

      build_pass(outcomes).call(pairs, state)

      expect(pairs.first.last.result).to eq(:expired)
      expect(pairs.first.last.attempts.first.result).to eq('expired')
    end
  end
end
# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength
# rubocop:enable RSpec/MultipleMemoizedHelpers
