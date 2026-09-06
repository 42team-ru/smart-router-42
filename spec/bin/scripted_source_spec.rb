# frozen_string_literal: true

require 'json'
require 'open3'
require 'tmpdir'

# Сценарный источник исходов, доступный из CLI и конфига.
#
# Смысл проверок: до этого Scripted и AlwaysFail существовали классами, были
# покрыты юнит-спеками, но собрать их из bin/route было нельзя — case знал
# только deterministic и always_ok. Здесь проверяется именно доступность
# снаружи и внятность ошибок, а не поведение самих классов.
#
# rubocop:disable RSpec/DescribeClass -- bin/route исполняемый скрипт, а не класс
# rubocop:disable RSpec/MultipleExpectations -- один прогон процесса проверяется
# набором связанных утверждений, дробить — терять контекст сценария
# rubocop:disable RSpec/ExampleLength -- каждый сценарий готовит каталог и
# запускает отдельный процесс
RSpec.describe 'bin/route --outcomes scripted' do
  let(:bin_route) { File.expand_path('../../bin/route', __dir__) }
  let(:queue_path) { reference_path('operations_queue_10.json') }
  let(:demo_config) do
    File.expand_path('../../config/examples/scripted_cascade.yml', __dir__)
  end

  def run_route(*args)
    Open3.capture3('ruby', bin_route, *args)
  end

  def decisions_in(dir)
    JSON.parse(File.read(File.join(dir, 'routing_decisions_test.json')))
  end

  describe 'демо-сценарий каскада' do
    it 'воспроизводит отказ и переход к следующему провайдеру' do
      Dir.mktmpdir do |tmp|
        _stdout, _stderr, status = run_route(queue_path, '--config', demo_config,
                                             '--out-dir', tmp)
        expect(status.exitstatus).to eq(0)

        op101 = decisions_in(tmp).find { |d| d['operation_id'] == 'op_101' }
        real_attempts = op101['attempts'].select { |a| a['decision'] == 'selected' }

        expect(real_attempts.size).to eq(2)
        expect(real_attempts.first).to include('provider' => 'vipay', 'result' => 'rejected')
        expect(real_attempts.last).to include('provider' => 'payflow', 'result' => 'approved',
                                              'reason' => 'next_in_cascade')
        expect(op101['selected_provider']).to eq('payflow')
      end
    end

    it 'даёт тот же результат на двух прогонах' do
      Dir.mktmpdir do |first|
        Dir.mktmpdir do |second|
          [first, second].each do |dir|
            run_route(queue_path, '--config', demo_config, '--out-dir', dir)
          end

          expect(File.read(File.join(first, 'routing_decisions_test.json')))
            .to eq(File.read(File.join(second, 'routing_decisions_test.json')))
        end
      end
    end

    it 'не зависит от seed: сценарий сильнее хеша' do
      Dir.mktmpdir do |tmp|
        Dir.mktmpdir do |other|
          run_route(queue_path, '--config', demo_config, '--seed', '42', '--out-dir', tmp)
          run_route(queue_path, '--config', demo_config, '--seed', '999', '--out-dir', other)

          expect(File.read(File.join(tmp, 'routing_decisions_test.json')))
            .to eq(File.read(File.join(other, 'routing_decisions_test.json')))
        end
      end
    end
  end

  describe 'ошибки конфигурации источника' do
    it 'требует сценарий, если источник выбран флагом' do
      _stdout, stderr, status = run_route(queue_path, '--outcomes', 'scripted')

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('scripted требует сценарий')
    end

    it 'сообщает про отсутствующий файл, а не падает трейсом' do
      _stdout, stderr, status = run_route(queue_path, '--outcomes', 'scripted',
                                          '--script', 'нет-такого-файла.yml')

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Файл сценария не найден')
      expect(stderr).not_to include('backtrace')
    end

    it 'ловит опечатку в имени источника на загрузке конфига' do
      Dir.mktmpdir do |tmp|
        config = File.join(tmp, 'typo.yml')
        File.write(config, "strategy: count_share\nfallback_provider: spacepayments\n" \
                           "outcomes:\n  source: determinstic\n")

        _stdout, stderr, status = run_route(queue_path, '--config', config, '--out-dir', tmp)

        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('outcomes.source должен быть одним из')
        expect(stderr).to include('determinstic')
      end
    end

    it 'требует outcomes.script, когда источник задан в конфиге' do
      Dir.mktmpdir do |tmp|
        config = File.join(tmp, 'scripted.yml')
        File.write(config, "strategy: count_share\nfallback_provider: spacepayments\n" \
                           "outcomes:\n  source: scripted\n")

        _stdout, stderr, status = run_route(queue_path, '--config', config, '--out-dir', tmp)

        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('требует outcomes.script')
      end
    end
  end

  describe 'сценарий внутри конфига' do
    def config_with(script_body, dir)
      path = File.join(dir, 'inline.yml')
      File.write(path, "strategy: count_share\nfallback_provider: spacepayments\n" \
                       "outcomes:\n  source: scripted\n  script:\n#{script_body}")
      path
    end

    it 'ловит недопустимый исход на загрузке конфига, а не в середине очереди' do
      Dir.mktmpdir do |tmp|
        config = config_with("    op_101:\n      vipay: одобрено\n", tmp)

        _stdout, stderr, status = run_route(queue_path, '--config', config, '--out-dir', tmp)

        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('outcomes.script.op_101.vipay')
        expect(stderr).to include('недопустимый исход')
      end
    end

    it 'требует отображение провайдер -> исход, а не строку' do
      Dir.mktmpdir do |tmp|
        config = config_with("    op_101: approved\n", tmp)

        _stdout, stderr, status = run_route(queue_path, '--config', config, '--out-dir', tmp)

        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('должен быть отображением')
      end
    end

    it 'падает с именем пары, если сценарий неполон' do
      Dir.mktmpdir do |tmp|
        config = config_with("    op_101:\n      vipay: rejected\n      payflow: approved\n", tmp)

        _stdout, stderr, status = run_route(queue_path, '--config', config, '--out-dir', tmp)

        expect(status.exitstatus).not_to eq(0)
        expect(stderr).to include('нет исхода для')
      end
    end
  end

  describe 'always_fail' do
    # Дефолт cascade.exhausted -- last_candidate (эталон
    # reference_decisions.json/`make validate`) -- всегда отказывающий
    # always_fail НЕ доезжает до spacepayments: каскад заканчивается на
    # последнем реальном кандидате с его фактическим (rejected) результатом.
    it 'доступен из CLI и на дефолтном каскаде НЕ доезжает до spacepayments' do
      Dir.mktmpdir do |tmp|
        _stdout, _stderr, status = run_route(queue_path, '--outcomes', 'always_fail',
                                             '--out-dir', tmp)
        expect(status.exitstatus).to eq(0)

        decisions = decisions_in(tmp)
        expect(decisions).to all(include('simulated_result' => 'rejected'))
        expect(decisions.map { |d| d['selected_provider'] }).not_to include('spacepayments')
      end
    end

    # Буквальное прочтение ТЗ (exhausted: fallback_provider) остаётся доступно
    # через конфиг -- регресс-проверка, что переключатель по-прежнему
    # работает, а не только дефолт.
    it 'exhausted: fallback_provider — исчерпанный каскад доезжает до spacepayments' do
      Dir.mktmpdir do |tmp|
        config = File.join(tmp, 'fallback_provider.yml')
        File.write(config, "strategy: count_share\nfallback_provider: spacepayments\n" \
                           "cascade:\n  exhausted: fallback_provider\n")

        _stdout, _stderr, status = run_route(queue_path, '--outcomes', 'always_fail',
                                             '--config', config, '--out-dir', tmp)
        expect(status.exitstatus).to eq(0)

        decisions = decisions_in(tmp)
        expect(decisions).to all(include('simulated_result' => 'rejected'))
        expect(decisions.map { |d| d['selected_provider'] }).to all(eq('spacepayments'))
      end
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/ExampleLength
