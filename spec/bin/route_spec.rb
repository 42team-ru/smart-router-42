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

  # CFG-2 (W3): конфиг доезжает до пайплайна. Боевой config/routing.yml спеки
  # только читают — правки уходят во временный файл в Dir.mktmpdir.
  describe 'конфигурация' do
    let(:production_config) { File.expand_path('../../config/routing.yml', __dir__) }

    def config_with(dir, line, replacement)
      source = File.read(production_config)
      raise "строка #{line.inspect} исчезла из config/routing.yml" unless source.include?(line)

      path = File.join(dir, 'routing.yml')
      File.write(path, source.sub(line, replacement))
      path
    end

    def distribution(dir)
      decisions = JSON.parse(File.read(File.join(dir, 'routing_decisions_test.json')))
      decisions.each_with_object(Hash.new(0)) { |d, acc| acc[d['selected_provider']] += 1 }
    end

    def config_with_replacements(dir, replacements)
      source = File.read(production_config)
      replacements.each do |line, replacement|
        raise "строка #{line.inspect} исчезла из config/routing.yml" unless source.include?(line)

        source = source.sub(line, replacement)
      end
      path = File.join(dir, 'routing.yml')
      File.write(path, source)
      path
    end

    it 'берёт стратегию из YAML, когда --strategy не передан' do
      Dir.mktmpdir do |tmp|
        config = config_with(tmp, 'strategy: count_share', 'strategy: load')

        _stdout, stderr, status = run_route(queue_path, '--out-dir', tmp, '--config', config)

        expect(status.exitstatus).to eq(0), stderr
        expect(distribution(tmp)).to eq('quickpay' => 9, 'payflow' => 1)
      end
    end

    it '--strategy перекрывает ключ strategy из YAML' do
      Dir.mktmpdir do |tmp|
        config = config_with(tmp, 'strategy: count_share', 'strategy: load')

        _stdout, stderr, status = run_route(queue_path, '--out-dir', tmp, '--config', config,
                                            '--strategy', 'priority')

        expect(status.exitstatus).to eq(0), stderr
        expect(distribution(tmp)).to eq('vipay' => 4, 'payflow' => 3, 'quickpay' => 3)
      end
    end

    it 'на опечатку в имени стратегии падает кодом 1 и называет конфиг' do
      Dir.mktmpdir do |tmp|
        config = config_with(tmp, 'strategy: count_share', 'strategy: count_shar')

        _stdout, stderr, status = run_route(queue_path, '--out-dir', tmp, '--config', config)

        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('config/routing.yml').and include('count_share')
      end
    end

    it 'на непустой layers падает кодом 1, а не игнорирует его молча' do
      Dir.mktmpdir do |tmp|
        config = config_with(tmp, 'layers: []', 'layers: [conversion]')

        _stdout, stderr, status = run_route(queue_path, '--out-dir', tmp, '--config', config)

        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('layer').and include('conversion')
      end
    end

    it 'на отсутствующий файл конфига даёт сообщение, а не трейс' do
      Dir.mktmpdir do |tmp|
        _stdout, stderr, status = run_route(queue_path, '--out-dir', tmp,
                                            '--config', 'no/such/file.yml')

        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('no/such/file.yml')
        expect(stderr).not_to include('backtrace')
      end
    end

    # rubocop:disable-next RSpec/ExampleLength, RSpec/MultipleExpectations -- проверяем оба источника исходов и их приоритет.
    it 'читает outcomes.source из YAML, а CLI его перекрывает' do
      Dir.mktmpdir do |tmp|
        config = config_with(tmp, 'source: deterministic', 'source: always_ok')
        _stdout, stderr, status = run_route(queue_path, '--out-dir', tmp, '--config', config)
        decisions = JSON.parse(File.read(File.join(tmp, 'routing_decisions_test.json')))

        expect(status.exitstatus).to eq(0), stderr
        expect(decisions.map { |decision| decision['simulated_result'] }).to all(eq('approved'))

        _stdout, stderr, status = run_route(
          queue_path, '--out-dir', tmp, '--config', config, '--outcomes', 'deterministic'
        )
        overridden = JSON.parse(File.read(File.join(tmp, 'routing_decisions_test.json')))

        expect(status.exitstatus).to eq(0), stderr
        results = overridden.map { |decision| decision['simulated_result'] }
        expect(results).to include('rejected').or include('expired')
      end
    end

    # rubocop:disable-next RSpec/ExampleLength, RSpec/MultipleExpectations -- сравниваются независимые настройки YAML и CLI.
    it 'читает seed и calibrate_from_history из YAML, CLI перекрывает seed' do
      Dir.mktmpdir do |tmp|
        baseline = config_with_replacements(tmp, {})

        run_route(queue_path, '--out-dir', tmp, '--config', baseline)
        baseline_output = File.binread(File.join(tmp, 'routing_decisions_test.json'))
        seed = config_with_replacements(tmp, 'seed: 42' => 'seed: 777')
        run_route(queue_path, '--out-dir', tmp, '--config', seed)
        seeded_output = File.binread(File.join(tmp, 'routing_decisions_test.json'))
        run_route(queue_path, '--out-dir', tmp, '--config', seed, '--seed', '42')
        overridden_output = File.binread(File.join(tmp, 'routing_decisions_test.json'))
        uncalibrated = config_with_replacements(
          tmp, 'calibrate_from_history: true' => 'calibrate_from_history: false'
        )
        run_route(queue_path, '--out-dir', tmp, '--config', uncalibrated)
        uncalibrated_output = File.binread(File.join(tmp, 'routing_decisions_test.json'))

        expect(seeded_output).not_to eq(baseline_output)
        expect(overridden_output).to eq(baseline_output)
        expect(uncalibrated_output).not_to eq(baseline_output)
      end
    end

    it 'один раз предупреждает о неподдерживаемых полях rate_limits и obligations' do
      Dir.mktmpdir do |tmp|
        _stdout, stderr, status = run_route(queue_path, '--out-dir', tmp)

        expect(status.exitstatus).to eq(0)
        expect(stderr).to include('rate_limits заданы для quickpay, vipay',
                                  'requests_per_minute_limit')
        expect(stderr).to include('obligations заданы для payflow, vipay',
                                  'daily_turnover_min/daily_turnover_max')
      end
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/ExampleLength
