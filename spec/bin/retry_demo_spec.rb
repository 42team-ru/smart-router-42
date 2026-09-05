# frozen_string_literal: true

require 'json'
require 'open3'
require 'tmpdir'

# На боевом seed 42 публичная очередь не содержит ни одного `rejected` --
# жюри не увидит ни повторной попытки, ни `next_in_cascade`. README несёт
# команду демо ретрая с этим же SEED, подобранным перебором `1..99` по
# возрастанию (первое значение, где `next_in_cascade` появляется). Если
# кто-то поменяет число в README, не поменяв здесь, — спек и README
# разойдутся, и это будет замечено, а не тихо забыто.
#
# rubocop:disable RSpec/DescribeClass -- сценарий CLI, а не класс
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength -- одна операция
# проверяется набором связанных утверждений о её же attempts, дробить — терять
# контекст сценария.
RSpec.describe 'демо ретрая (README §6)' do
  let(:seed) { 1 }
  let(:bin_route) { File.expand_path('../../bin/route', __dir__) }
  let(:queue_path) { reference_path('operations_queue_10.json') }

  def run_route(*args)
    Open3.capture3('ruby', bin_route, *args)
  end

  it 'seed из README даёт операцию с двумя реальными попытками и next_in_cascade' do
    Dir.mktmpdir do |tmp|
      _stdout, stderr, status = run_route(queue_path, '--seed', seed.to_s, '--out-dir', tmp)
      decisions = JSON.parse(File.read(File.join(tmp, 'routing_decisions_test.json')))
      eligible = JSON.parse(
        File.read(reference_path('reference_decisions.json'))
      ).fetch('eligible_providers')

      retried = decisions.find do |decision|
        decision['attempts'].any? { |attempt| attempt['reason'] == 'next_in_cascade' }
      end

      expect(status.exitstatus).to eq(0), stderr
      expect(retried).not_to be_nil
      real_attempts = retried['attempts'].select { |attempt| attempt['decision'] == 'selected' }
      expect(real_attempts.size).to be >= 2
      expect(real_attempts.last['reason']).to eq('next_in_cascade')
      expect(eligible.fetch(retried['operation_id'])).to include(retried['selected_provider'])
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/ExampleLength
