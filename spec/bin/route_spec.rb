# frozen_string_literal: true

require 'json'
require 'open3'
require 'tmpdir'

# rubocop:disable RSpec/DescribeClass -- bin/route исполняемый скрипт, а не класс
# rubocop:disable RSpec/MultipleExpectations -- сценарии CLI проверяются набором связанных
# утверждений об одном прогоне процесса, дробить их — терять контекст сценария
# rubocop:disable RSpec/ExampleLength -- каждый сценарий готовит временный каталог и
# запускает отдельный процесс, короче не выходит
RSpec.describe 'bin/route' do
  let(:bin_route) { File.expand_path('../../bin/route', __dir__) }
  let(:queue_path) { reference_path('operations_queue_10.json') }
  let(:queue) { JSON.parse(File.read(queue_path)) }

  # Явный интерпретатор вместо прямого запуска bin_route: на Windows нет
  # ассоциации для shebang-скрипта без расширения, execve падает с ENOEXEC.
  def run_route(*args)
    Open3.capture3('ruby', bin_route, *args)
  end

  it 'завершается с кодом 0 и пишет оба файла с точными именами' do
    Dir.mktmpdir do |tmp|
      _stdout, _stderr, status = run_route(queue_path, '--out-dir', tmp)

      expect(status.exitstatus).to eq(0)
      expect(File.exist?(File.join(tmp, 'routing_decisions_test.json'))).to be(true)
      expect(File.exist?(File.join(tmp, 'routing_report_test.json'))).to be(true)
    end
  end

  it 'пишет по одному решению на операцию, в порядке очереди' do
    Dir.mktmpdir do |tmp|
      run_route(queue_path, '--out-dir', tmp)

      decisions = JSON.parse(File.read(File.join(tmp, 'routing_decisions_test.json')))

      expect(decisions.size).to eq(10)
      expect(decisions.map { |d| d['operation_id'] }).to eq(queue.map { |op| op['operation_id'] })
    end
  end

  it 'каждое решение и каждый attempt содержат обязательные поля' do
    Dir.mktmpdir do |tmp|
      run_route(queue_path, '--out-dir', tmp)

      decisions = JSON.parse(File.read(File.join(tmp, 'routing_decisions_test.json')))

      decisions.each do |decision|
        expect(decision).to include('operation_id', 'selected_provider', 'attempts')
        expect(decision['attempts']).not_to be_empty

        decision['attempts'].each do |attempt|
          expect(attempt).to include('provider', 'decision', 'reason')
          expect(%w[selected skipped].include?(attempt['decision'])).to be(true)
        end
      end
    end
  end

  it 'отчёт содержит обязательные ключи и верные period/total_operations' do
    Dir.mktmpdir do |tmp|
      run_route(queue_path, '--out-dir', tmp)

      report = JSON.parse(File.read(File.join(tmp, 'routing_report_test.json')))

      expect(report).to include(
        'period', 'total_operations', 'distribution',
        'skip_reasons', 'projected_daily_utilization', 'recommendations'
      )
      expect(report['total_operations']).to eq(10)
      expect(report['period']).to eq('2026-07-30')
    end
  end

  it 'даёт побайтово одинаковый результат на двух прогонах' do
    Dir.mktmpdir do |tmp_a|
      Dir.mktmpdir do |tmp_b|
        run_route(queue_path, '--out-dir', tmp_a)
        run_route(queue_path, '--out-dir', tmp_b)

        %w[routing_decisions_test.json routing_report_test.json].each do |filename|
          content_a = File.binread(File.join(tmp_a, filename))
          content_b = File.binread(File.join(tmp_b, filename))

          expect(content_a).to eq(content_b)
        end
      end
    end
  end

  it 'выбирает эталонных провайдеров без fallback и пишет причины пропусков op_103' do
    Dir.mktmpdir do |tmp|
      run_route(queue_path, '--out-dir', tmp)
      decisions = JSON.parse(File.read(File.join(tmp, 'routing_decisions_test.json')))
      selected = decisions.to_h do |decision|
        [decision['operation_id'], decision['selected_provider']]
      end
      reference_decision = decisions.find { |decision| decision['operation_id'] == 'op_103' }

      expect(selected).to include('op_103' => 'quickpay', 'op_104' => 'quickpay',
                                  'op_107' => 'payflow', 'op_108' => 'quickpay')
      expect(selected.values).not_to include('spacepayments')
      expect(reference_decision['attempts']).to include(
        include('provider' => 'vipay', 'decision' => 'skipped'),
        include('provider' => 'payflow', 'decision' => 'skipped')
      )
    end
  end

  it 'без аргументов завершается с ненулевым кодом и сообщением на STDERR' do
    _stdout, stderr, status = run_route

    expect(status.exitstatus).not_to eq(0)
    expect(stderr).not_to be_empty
  end

  it 'на несуществующем файле очереди завершается с ненулевым кодом и сообщением' do
    Dir.mktmpdir do |tmp|
      missing_path = File.join(tmp, 'no_such_queue.json')

      _stdout, stderr, status = run_route(missing_path, '--out-dir', tmp)

      expect(status.exitstatus).not_to eq(0)
      expect(stderr).not_to be_empty
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/ExampleLength
