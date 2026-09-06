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

  # spec/contracts/fixtures_spec.rb проверяет форму "recommendations — массив
  # строк" только на статической фикстуре (spec/fixtures/contracts/report.json),
  # не на реальном выводе bin/route -- эту дыру впервые делают значимой
  # (deviation_causes и retarget получают вычисляемое содержимое, а не
  # пустышку/константу), и здесь она закрывается на живом прогоне.
  it 'deviation_causes и recommendations — массивы строк с числом на реальном прогоне' do
    Dir.mktmpdir do |tmp|
      run_route(queue_path, '--out-dir', tmp)

      report = JSON.parse(File.read(File.join(tmp, 'routing_report_test.json')))

      expect(report['deviation_causes']).to all(be_a(String).and(match(/\d/)))
      expect(report['recommendations']).to all(be_a(String).and(match(/\d/)))
      expect(report['deviation_causes']).not_to be_empty
      expect(report['recommendations']).to include(a_string_starting_with('retarget:'))
    end
  end

  # Не переспецифицирует построчный формат (это спек
  # spec/reporting/console_summary_spec.rb) -- только ловит факт стыковки
  # Reporting::ConsoleSummary в bin/route.
  it 'печатает в STDOUT решение по каждой операции и итоговую сводку' do
    Dir.mktmpdir do |tmp|
      stdout, _stderr, = run_route(queue_path, '--out-dir', tmp)

      queue.each { |operation| expect(stdout).to include(operation['operation_id']) }
      expect(stdout).to include('competitive_ratio=')
      expect(stdout).to include('Fallback:')
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

  it 'выбирает эталонных провайдеров, включая op_103/op_104 (reference_decisions.json)' do
    Dir.mktmpdir do |tmp|
      # Явный --outcomes deterministic: боевой конфиг сдаёт always_ok по
      # указанию организаторов (docs/RUNBOOK.md §2), а эталон организаторов
      # описывает именно поведение под моделью исходов — таймаут на op_103 и
      # каскад, который на нём же и останавливается.
      run_route(queue_path, '--out-dir', tmp, '--outcomes', 'deterministic', '--seed', '42')
      decisions = JSON.parse(File.read(File.join(tmp, 'routing_decisions_test.json')))
      selected = decisions.to_h do |decision|
        [decision['operation_id'], decision['selected_provider']]
      end
      reference_decision = decisions.find { |decision| decision['operation_id'] == 'op_103' }

      # op_103/op_104: единственный допустимый кандидат -- quickpay (эталон
      # организаторов, reference/data/reference_decisions.json →
      # deterministic_cases, required_provider: quickpay). На seed 42 он
      # отвечает таймаутом/отказом -- дефолты cascade.on_timeout: stop и
      # cascade.exhausted: last_candidate останавливают/завершают каскад на
      # нём же, а не подключают spacepayments поверх. Это то, что проверяет
      # `make validate`.
      expect(selected).to include('op_103' => 'quickpay', 'op_104' => 'quickpay',
                                  'op_107' => 'payflow', 'op_108' => 'quickpay')
      expect(reference_decision['attempts']).to include(
        include('provider' => 'vipay', 'decision' => 'skipped'),
        include('provider' => 'payflow', 'decision' => 'skipped'),
        include('provider' => 'quickpay', 'decision' => 'selected', 'result' => 'expired')
      )
      expect(reference_decision['attempts'].map do |a|
        a['provider']
      end).not_to include('spacepayments')
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

  # Конфиг доезжает до пайплайна. Боевой config/routing.yml спеки только
  # читают — правки уходят во временный файл в Dir.mktmpdir.
  describe 'конфигурация' do
    let(:production_config) { File.expand_path('../../config/routing.yml', __dir__) }

    # Временные конфиги меняют strategy/layers, поэтому comparison удаляется.
    def strip_comparison(source)
      source.sub(/\ncomparison:.*\z/m, "\n")
    end

    # Производные конфиги используют deterministic для проверяемых исходов.
    def deterministic_outcomes(source)
      raise 'ключ outcomes.source исчез из config/routing.yml' unless
        source.include?('source: always_ok')

      source.sub('source: always_ok', 'source: deterministic')
    end

    def config_with(dir, line, replacement)
      source = deterministic_outcomes(File.read(production_config))
      raise "строка #{line.inspect} исчезла из config/routing.yml" unless source.include?(line)

      path = File.join(dir, 'routing.yml')
      File.write(path, strip_comparison(source.sub(line, replacement)))
      path
    end

    def distribution(dir)
      decisions = JSON.parse(File.read(File.join(dir, 'routing_decisions_test.json')))
      decisions.each_with_object(Hash.new(0)) { |d, acc| acc[d['selected_provider']] += 1 }
    end

    def config_with_replacements(dir, replacements)
      source = deterministic_outcomes(File.read(production_config))
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
        # Перемерено с боевыми layers: [share_ceiling, budget_headroom] и
        # share_ceiling.tolerance_bp: 1000; проверяет именно YAML-стратегию.
        expect(distribution(tmp)).to eq('quickpay' => 4, 'vipay' => 3, 'payflow' => 3)
      end
    end

    it '--strategy перекрывает ключ strategy из YAML' do
      Dir.mktmpdir do |tmp|
        config = config_with(tmp, 'strategy: count_share', 'strategy: load')

        _stdout, stderr, status = run_route(queue_path, '--out-dir', tmp, '--config', config,
                                            '--strategy', 'priority')

        expect(status.exitstatus).to eq(0), stderr
        # Перемерено с боевыми layers/tolerance; CLI всё ещё перекрывает YAML.
        expect(distribution(tmp)).to eq('vipay' => 4, 'payflow' => 2, 'quickpay' => 4)
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

    it 'на неизвестный слой падает кодом 1, а не игнорирует его молча' do
      Dir.mktmpdir do |tmp|
        config = config_with(
          tmp, 'layers: [share_ceiling, budget_headroom]', 'layers: [unknown_layer]'
        )

        _stdout, stderr, status = run_route(queue_path, '--out-dir', tmp, '--config', config)

        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('layer').and include('unknown_layer')
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
        # simulated_result (итог) не годится для always_ok-прогона выше -- он
        # approved на любой попытке по конструкции. Здесь проверяем, что
        # deterministic на том же конфиге всё равно даёт не только approved
        # хотя бы на уровне отдельных попыток (rejected/expired у op_103,
        # op_104 и других) -- always_ok такого дать не может.
        attempt_results = overridden.flat_map do |decision|
          decision['attempts'].map { |attempt| attempt['result'] }
        end
        expect(attempt_results).to include('rejected').or include('expired')
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

    # Дефолтный снапшот — data/providers.json, где daily_turnover_min/max и
    # requests_per_minute_limit уже реальные поля, поэтому ни предупреждение
    # про obligations, ни про rate_limits больше не печатается.
    it 'на дефолтном снапшоте не предупреждает ни про rate_limits, ни про obligations' do
      Dir.mktmpdir do |tmp|
        _stdout, stderr, status = run_route(queue_path, '--out-dir', tmp)

        expect(status.exitstatus).to eq(0)
        expect(stderr).not_to include('rate_limits заданы для')
        expect(stderr).not_to include('obligations заданы для')
      end
    end

    # Блоки объявляет сам спек: из боевого конфига они убраны как дубль
    # data/providers.json, где daily_turnover_min/max и
    # requests_per_minute_limit уже проставлены. Предупреждение при этом
    # остаётся частью контракта CLI — его и проверяем.
    it 'на пристинном снапшоте организаторов предупреждает и про rate_limits, и про obligations' do
      Dir.mktmpdir do |tmp|
        overrides = <<~YAML
          obligations:
            payflow: { daily_turnover_min: 2000000 }
            vipay: { daily_turnover_max: 5000000 }
          rate_limits:
            vipay: 7
            payflow: 10
            quickpay: 15
        YAML
        config = config_with(tmp, 'fallback_provider: spacepayments',
                             "#{overrides}\nfallback_provider: spacepayments")
        _stdout, stderr, status = run_route(queue_path, '--out-dir', tmp, '--config', config,
                                            '--providers', reference_path('providers.json'))

        expect(status.exitstatus).to eq(0)
        expect(stderr).to include('rate_limits заданы для payflow, quickpay, vipay',
                                  'requests_per_minute_limit')
        expect(stderr).to include('obligations заданы для payflow, vipay',
                                  'daily_turnover_min/daily_turnover_max')
      end
    end

    # Каскад проверяется через CLI с паспортными conversion_24h.
    describe 'cascade' do
      def write_queue(dir, operations)
        path = File.join(dir, 'queue.json')
        File.write(path, JSON.generate(operations))
        path
      end

      # Замена целого блока не затрагивает одноимённые строки в комментариях.
      def cascade_block(exhausted: 'last_candidate', on_timeout: 'stop')
        "cascade:\n  exhausted: #{exhausted}\n  on_timeout: #{on_timeout}\n"
      end

      def cascade_config(dir, exhausted: 'last_candidate', on_timeout: 'stop')
        block = cascade_block(exhausted: exhausted, on_timeout: on_timeout)
        config_with_replacements(dir, { 'calibrate_from_history: true' =>
                                          'calibrate_from_history: false',
                                        cascade_block => block })
      end

      # Единственный допустимый провайдер quickpay получает rejected на seed 42.
      def exhausted_operation
        { 'operation_id' => 'test_op_2', 'created_at' => '2026-07-30T09:05:00+03:00',
          'amount' => 5000, 'bank' => 'qiwi', 'card_brand' => nil, 'payout_requisite' => {} }
      end

      # Quickpay получает expired, а payflow на второй попытке — approved.
      def timeout_operation
        { 'operation_id' => 'test_op_1', 'created_at' => '2026-07-30T09:05:00+03:00',
          'amount' => 2000, 'bank' => 'alfa', 'card_brand' => nil, 'payout_requisite' => {} }
      end

      it 'exhausted: last_candidate (дефолт) — исчерпанный каскад НЕ подключает spacepayments' do
        Dir.mktmpdir do |tmp|
          queue = write_queue(tmp, [exhausted_operation])
          config = cascade_config(tmp)

          _stdout, stderr, status = run_route(queue, '--out-dir', tmp, '--config', config)
          decisions = JSON.parse(File.read(File.join(tmp, 'routing_decisions_test.json')))

          expect(status.exitstatus).to eq(0), stderr
          expect(decisions.first['selected_provider']).to eq('quickpay')
          expect(decisions.first['simulated_result']).to eq('rejected')
          expect(decisions.first['attempts'].map do |a|
            a['provider']
          end).not_to include('spacepayments')
        end
      end

      it 'exhausted: fallback_provider — исчерпанный каскад добавляет попытку fallback' do
        Dir.mktmpdir do |tmp|
          queue = write_queue(tmp, [exhausted_operation])
          config = cascade_config(tmp, exhausted: 'fallback_provider')

          _stdout, stderr, status = run_route(queue, '--out-dir', tmp, '--config', config)
          decisions = JSON.parse(File.read(File.join(tmp, 'routing_decisions_test.json')))
          attempts = decisions.first['attempts']

          expect(status.exitstatus).to eq(0), stderr
          expect(decisions.first['selected_provider']).to eq('spacepayments')
          expect(attempts.last).to include(
            'provider' => 'spacepayments', 'decision' => 'selected',
            'reason' => 'fallback_after_cascade', 'attempt_no' => 2
          )
          expect(attempts.last['details']).to match(/\d/)
        end
      end

      it 'on_timeout: stop (дефолт) — expired останавливает каскад одной попыткой' do
        Dir.mktmpdir do |tmp|
          queue = write_queue(tmp, [timeout_operation])
          config = cascade_config(tmp)

          _stdout, stderr, status = run_route(queue, '--out-dir', tmp, '--config', config)
          decisions = JSON.parse(File.read(File.join(tmp, 'routing_decisions_test.json')))

          expect(status.exitstatus).to eq(0), stderr
          expect(decisions.first['selected_provider']).to eq('quickpay')
          expect(decisions.first['simulated_result']).to eq('expired')
          expect(decisions.first['attempts'].count { |a| a['decision'] == 'selected' }).to eq(1)
        end
      end

      it 'on_timeout: continue — expired не тормозит каскад, побеждает approved' do
        Dir.mktmpdir do |tmp|
          queue = write_queue(tmp, [timeout_operation])
          config = cascade_config(tmp, on_timeout: 'continue')

          _stdout, stderr, status = run_route(queue, '--out-dir', tmp, '--config', config)
          decisions = JSON.parse(File.read(File.join(tmp, 'routing_decisions_test.json')))
          attempts = decisions.first['attempts']

          expect(status.exitstatus).to eq(0), stderr
          expect(decisions.first['selected_provider']).to eq('payflow')
          expect(decisions.first['simulated_result']).to eq('approved')
          selected = attempts.select { |a| a['decision'] == 'selected' }
          expect(selected.map { |a| [a['provider'], a['result']] })
            .to eq([%w[quickpay expired], %w[payflow approved]])
        end
      end

      it 'на опечатку в значении cascade.exhausted падает кодом 1 без трейса' do
        Dir.mktmpdir do |tmp|
          config = config_with_replacements(
            tmp, { cascade_block => cascade_block(exhausted: 'fallback') }
          )

          _stdout, stderr, status = run_route(queue_path, '--out-dir', tmp, '--config', config)

          expect(status.exitstatus).to eq(1)
          expect(stderr).to include('cascade.exhausted').and include('fallback')
          expect(stderr).not_to include('backtrace')
        end
      end
    end

    # comparison строится один раз в bin/route и идёт только в консоль/report
    # -- decisions.json не задевает (spec/offline/isolation_spec.rb стережёт
    # то же самое на уровне lib/).
    describe 'comparison' do
      def comparison_yaml_block
        <<~YAML
          comparison:
            - { name: round_robin,        strategy: round_robin, layers: [] }
            - { name: count_share,        strategy: count_share, layers: [] }
            - { name: count_share+layers, strategy: count_share, layers: [share_ceiling, budget_headroom] }
        YAML
      end

      it 'печатает таблицу сравнения на боевом конфиге (comparison включён по умолчанию)' do
        Dir.mktmpdir do |tmp|
          stdout, stderr, status = run_route(queue_path, '--out-dir', tmp)

          expect(status.exitstatus).to eq(0), stderr
          expect(stdout).to include('Сравнение (офлайн, не влияет на решения)')
          expect(stdout).to include('count_share+layers (baseline)')
        end
      end

      it 'report несёт comparison.variants с именами и в порядке конфига' do
        Dir.mktmpdir do |tmp|
          run_route(queue_path, '--out-dir', tmp)
          report = JSON.parse(File.read(File.join(tmp, 'routing_report_test.json')))

          expect(report['comparison']['variants'].keys)
            .to eq(%w[round_robin count_share count_share+layers])
          expect(report['comparison']['baseline']).to eq('count_share+layers')
        end
      end

      it 'решения при включённом сравнении побайтово те же, что при выключенном' do
        Dir.mktmpdir do |tmp|
          with_comparison = config_with_replacements(tmp, {})
          _stdout1, stderr1, status1 = run_route(queue_path, '--out-dir', tmp,
                                                 '--config', with_comparison)
          enabled_decisions = File.binread(File.join(tmp, 'routing_decisions_test.json'))

          without_comparison = config_with_replacements(tmp, { comparison_yaml_block => '' })
          _stdout2, stderr2, status2 = run_route(queue_path, '--out-dir', tmp,
                                                 '--config', without_comparison)
          disabled_decisions = File.binread(File.join(tmp, 'routing_decisions_test.json'))
          disabled_report = JSON.parse(File.read(File.join(tmp, 'routing_report_test.json')))

          expect(status1.exitstatus).to eq(0), stderr1
          expect(status2.exitstatus).to eq(0), stderr2
          expect(disabled_decisions).to eq(enabled_decisions)
          expect(disabled_report).not_to have_key('comparison')
        end
      end
    end

    # Второй проход (Execution::PendingResolutionPass) поверх ВСЕЙ очереди --
    # op_103 таймаутит на quickpay на публичной очереди (см. тест выше про
    # op_103/op_104), поэтому она же служит живым доказательством секции.
    describe 'pending_resolution' do
      def pending_resolution_block(enabled: 'true')
        "pending_resolution:\n  enabled: #{enabled}\n"
      end

      def pending_resolution_config(dir, enabled)
        config_with_replacements(dir, { pending_resolution_block =>
                                          pending_resolution_block(enabled: enabled) })
      end

      it 'включён по умолчанию и несёт осмысленную секцию в отчёте (не заглушку)' do
        Dir.mktmpdir do |tmp|
          # Явный deterministic: под боевым always_ok таймаутов нет вовсе, и
          # закрывать статус-чеку нечего (см. deterministic_outcomes выше).
          _stdout, stderr, status = run_route(queue_path, '--out-dir', tmp,
                                              '--outcomes', 'deterministic', '--seed', '42')
          report = JSON.parse(File.read(File.join(tmp, 'routing_report_test.json')))
          pending = report['pending_resolution']

          expect(status.exitstatus).to eq(0), stderr
          # op_103 -- единственный expired на публичной очереди (см. тест про
          # op_103/op_104/reference_decisions.json выше), seed 42 на поздней
          # проверке (attempt_no -1) даёт approved -- перемерено на фактическом
          # прогоне, не подогнано.
          # Перемерено под боевыми layers [share_ceiling, budget_headroom] и
          # tolerance 1000: второй проход теперь получает два expired hold.
          expect(pending).to include('checked' => 2, 'resolved' => 2, 'approved' => 2,
                                     'rejected' => 0, 'still_pending' => 0,
                                     'freed_in_progress_count' => 2,
                                     'freed_in_progress_amount' => 198_000)
          expect(pending['utilization']['quickpay']['used_after'])
            .to be > pending['utilization']['quickpay']['used_before']
        end
      end

      it 'не меняет routing_decisions_test.json -- op_103 остаётся expired' do
        Dir.mktmpdir do |tmp|
          run_route(queue_path, '--out-dir', tmp,
                    '--outcomes', 'deterministic', '--seed', '42')
          decisions = JSON.parse(File.read(File.join(tmp, 'routing_decisions_test.json')))
          decision = decisions.find { |d| d['operation_id'] == 'op_103' }

          expect(decision['simulated_result']).to eq('expired')
          expect(decision['selected_provider']).to eq('quickpay')
        end
      end

      it 'enabled: false -- в отчёте нет ключа pending_resolution' do
        Dir.mktmpdir do |tmp|
          config = pending_resolution_config(tmp, false)
          _stdout, stderr, status = run_route(queue_path, '--out-dir', tmp, '--config', config)
          report = JSON.parse(File.read(File.join(tmp, 'routing_report_test.json')))

          expect(status.exitstatus).to eq(0), stderr
          expect(report).not_to have_key('pending_resolution')
        end
      end

      # Критерий приёмки: выключенный второй проход не меняет НИЧЕГО, кроме
      # появления своей секции в отчёте.
      #
      # Сравнение идёт между двумя прогонами, а НЕ с корневым
      # routing_report_test.json. Тот файл -- сдаваемый артефакт: он
      # перегенерируется из боевой очереди в час стопкода и вдобавок сам
      # генерируется с pending_resolution: true, поэтому анкер на него
      # ломается от любой из этих двух причин (см. docs/RUNBOOK.md, мина №1 --
      # ровно та же ловушка уже была в regression-спеке ниже).
      it 'enabled: false меняет только наличие секции, решения не трогает' do
        Dir.mktmpdir do |tmp|
          on = pending_resolution_config(tmp, true)
          _out1, err1, status1 = run_route(queue_path, '--out-dir', tmp, '--config', on)
          decisions_on = File.binread(File.join(tmp, 'routing_decisions_test.json'))
          report_on = JSON.parse(File.read(File.join(tmp, 'routing_report_test.json')))

          off = pending_resolution_config(tmp, false)
          _out2, err2, status2 = run_route(queue_path, '--out-dir', tmp, '--config', off)
          decisions_off = File.binread(File.join(tmp, 'routing_decisions_test.json'))
          report_off = JSON.parse(File.read(File.join(tmp, 'routing_report_test.json')))

          expect(status1.exitstatus).to eq(0), err1
          expect(status2.exitstatus).to eq(0), err2
          expect(decisions_off).to eq(decisions_on)
          expect(report_off).to eq(report_on.except('pending_resolution'))
        end
      end

      it 'на опечатку в pending_resolution.enabled падает кодом 1 без трейса' do
        Dir.mktmpdir do |tmp|
          config = config_with_replacements(
            tmp, { pending_resolution_block => pending_resolution_block(enabled: 'maybe') }
          )

          _stdout, stderr, status = run_route(queue_path, '--out-dir', tmp, '--config', config)

          expect(status.exitstatus).to eq(1)
          expect(stderr).to include('pending_resolution.enabled')
          expect(stderr).not_to include('backtrace')
        end
      end
    end

    # Регрессия использует отдельную фикстуру публичной очереди, а не артефакт сдачи.
    # Обновлять её следует только при намеренном изменении поведения:
    #   bundle exec bin/route reference/data/operations_queue_10.json --out-dir /tmp/reg
    #   cp /tmp/reg/routing_decisions_test.json spec/fixtures/regression/public_queue_decisions.json
    it 'дефолтный прогон побайтово не меняется (regression)' do
      Dir.mktmpdir do |tmp|
        _stdout, stderr, status = run_route(queue_path, '--out-dir', tmp)
        produced = File.binread(File.join(tmp, 'routing_decisions_test.json'))
        expected = File.binread(
          File.expand_path('../fixtures/regression/public_queue_decisions.json', __dir__)
        )

        expect(status.exitstatus).to eq(0), stderr
        expect(produced).to eq(expected)
      end
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/ExampleLength
