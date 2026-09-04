# frozen_string_literal: true

require 'routing/layers/budget_headroom'
require 'routing/layer_stack'
require 'routing/strategies/priority'

# T-4: «ψ сохраняет headroom payflow» (docs/TASKS.md). Буквальная формулировка
# T-4 ("прогон без ψ ловушку воспроизводит, с ψ — нет, op_107 не уходит в
# spacepayments") сегодня не воспроизводится вообще: Constraints::DailyLimit
# уже читает живое состояние (см. комментарий в spec/support/psi_trap_scenario.rb),
# поэтому индивидуально одобренная операция никогда не пробивает лимит
# провайдера суммарно — ни с ψ, ни без него. T-4 поэтому проверяется в двух
# частях:
#
#   1. Реальные данные, config/examples/adwords.yml — payflow остаётся за
#      op_107, для op_101/102/110 либо отсутствует, либо последний по
#      attempt_no среди selected. Уже написано и зелено в
#      spec/bin/adwords_config_spec.rb — не дублируется здесь.
#   2. Синтетическая фикстура (этот файл) — не "ловушка" в смысле нарушенного
#      лимита (его больше нет), а разница между двумя способами ЕГО НЕ
#      нарушить: без ψ payflow отдаётся жадно и дневной лимит останавливает
#      его в последний момент (payflow получает "skipped, daily_limit_exceeded"
#      и операция падает на следующего кандидата); с ψ budget_headroom видит
#      падающий запас раньше хард-лимита и просто не выбирает payflow, пока
#      запас не восстановится — payflow ни разу не участвует в каскаде,
#      headroom сохраняется буквально (daily_approved_amount не растёт вообще).
#
# payflow: лимит 100 000 ₽, 90 000 ₽ уже одобрено (T = 0.90 на старте). Две
# операции по 6 000 ₽ — после первой T = 0.96, вторая (96 000 + 6 000 =
# 102 000 > 100 000) пробила бы лимит и потому хард-отклоняется.
RSpec.describe 'сценарий-ловушка бюджета (T-4)' do
  describe 'без ψ — payflow отдаётся до упора, лимит останавливает его в последний момент' do
    it 'op_a уходит в payflow, op_b — в vipay после хард-отказа payflow' do
      result = PsiTrapScenario.run(strategy: Routing::Strategies::Priority.new)

      selected = result.fetch(:outcomes).transform_values { |outcome| outcome.selected.name }
      expect(selected).to eq('op_a' => 'payflow', 'op_b' => 'vipay')
    end

    # rubocop:disable-next RSpec/MultipleExpectations -- decision и reason образуют один факт.
    it 'payflow для op_b получает хард-отказ по дневному лимиту, а не просто уступает ранг' do
      result = PsiTrapScenario.run(strategy: Routing::Strategies::Priority.new)

      payflow_attempt = result.fetch(:outcomes).fetch('op_b').attempts
                              .find { |attempt| attempt.provider.name == 'payflow' }
      expect(payflow_attempt.decision).to eq('skipped')
      expect(payflow_attempt.reason).to eq('daily_limit_exceeded')
    end

    # rubocop:disable-next RSpec/MultipleExpectations -- оба факта об одном прогоне.
    it 'каждая операция по отдельности одобрена, а суммарный расход payflow не превышает лимит' do
      result = PsiTrapScenario.run(strategy: Routing::Strategies::Priority.new)

      expect(result.fetch(:outcomes).values.map(&:result)).to all(eq(:approved))
      expect(result.fetch(:payflow_real_total)).to be <= result.fetch(:payflow_real_limit)
    end
  end

  describe 'с ψ (budget_headroom) — payflow не участвует в каскаде вообще' do
    # Порог не подгонялся под зелёный тест: psi_micro(payflow) при T=0.90
    # (стартовый снапшот) посчитан прямым вызовом BudgetHeadroom#psi_micro на
    # объектах этой фикстуры и равен 95_163. Порог 200_000 заведомо выше — с
    # запасом, а не впритык к границе, — поэтому deviation(payflow) уже
    # положителен на первой же операции (200_000 − 95_163 = 104_737), а
    # deviation(vipay) остаётся 0 весь прогон (его psi_micro на старте —
    # 632_121, на порядок больше порога). budget_headroom поэтому переранжирует
    # payflow ниже vipay сразу, до того как payflow вообще будет затронут.
    let(:psi_layer) { Routing::Layers::BudgetHeadroom.new(psi_threshold_micro: 200_000) }
    let(:layers) { Routing::LayerStack.new([psi_layer]) }

    it 'обе операции уходят в vipay — payflow не выбирается ни разу' do
      result = PsiTrapScenario.run(strategy: Routing::Strategies::Priority.new, layers: layers)

      selected = result.fetch(:outcomes).transform_values { |outcome| outcome.selected.name }
      expect(selected).to eq('op_a' => 'vipay', 'op_b' => 'vipay')
    end

    it 'payflow не появляется в attempts ни для одной операции — его вообще не пробуют' do
      result = PsiTrapScenario.run(strategy: Routing::Strategies::Priority.new, layers: layers)

      result.fetch(:outcomes).each_value do |outcome|
        expect(outcome.attempts.map { |attempt| attempt.provider.name }).not_to include('payflow')
      end
    end

    it 'daily_approved_amount payflow остаётся на стартовом уровне — headroom буквально сохранён' do
      result = PsiTrapScenario.run(strategy: Routing::Strategies::Priority.new, layers: layers)

      expect(result.fetch(:payflow_real_total)).to eq(PsiTrapScenario.payflow.daily_approved_amount)
    end
  end
end
