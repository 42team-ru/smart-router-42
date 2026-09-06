# frozen_string_literal: true

require 'json'
require 'open3'
require 'tmpdir'

# rubocop:disable-next RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/ExampleLength -- проверяется один сквозной прогон.
RSpec.describe 'bin/route с конфигом AdWords' do
  let(:bin_route) { File.expand_path('../../bin/route', __dir__) }
  let(:queue_path) { reference_path('operations_queue_10.json') }
  let(:config_path) { File.expand_path('../../config/examples/adwords.yml', __dir__) }

  it 'отодвигает payflow при альтернативе и сохраняет op_107' do
    Dir.mktmpdir do |tmp|
      _stdout, stderr, status = Open3.capture3(
        'ruby', bin_route, queue_path, '--config', config_path, '--out-dir', tmp
      )
      decisions = JSON.parse(File.read(File.join(tmp, 'routing_decisions_test.json')))

      expect(status.exitstatus).to eq(0), stderr
      %w[op_101 op_102 op_110].each do |operation_id|
        expect(payflow_last_or_absent?(decisions, operation_id)).to be(true)
      end
      expect(decision_for(decisions, 'op_107')['selected_provider']).to eq('payflow')
      expect(decision_for(decisions, 'op_101')['attempts'].first['details'])
        .to include('budget_headroom', 'psi')
    end
  end

  # fallback_after_cascade (spacepayments поверх исчерпанного каскада,
  # cascade.exhausted: fallback_provider) не часть порядка, который расставляет
  # budget_headroom -- это отдельная попытка сверх каскада, не в счёт.
  def payflow_last_or_absent?(decisions, operation_id)
    selected = cascade_attempts(decisions, operation_id)
    payflow = selected.select { |attempt| attempt['provider'] == 'payflow' }
    selected_attempt_numbers = selected.map { |attempt| attempt['attempt_no'] }.compact
    payflow.empty? || payflow.last['attempt_no'] == selected_attempt_numbers.max
  end

  def cascade_attempts(decisions, operation_id)
    decision_for(decisions, operation_id)['attempts'].select do |attempt|
      attempt['decision'] == 'selected' && attempt['reason'] != 'fallback_after_cascade'
    end
  end

  def decision_for(decisions, operation_id)
    decisions.find { |decision| decision['operation_id'] == operation_id }
  end
end
