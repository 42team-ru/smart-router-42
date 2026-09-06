# frozen_string_literal: true

require 'csv'
require 'json'
require 'open3'
require 'tmpdir'

# Флаг --history появился под конкретный риск часа стопкода: организаторы могут
# выдать свою историю операций вместе с очередью. До него путь брался только из
# ключа history_path боевого конфига, то есть подмена требовала правки
# config/routing.yml под дедлайном — ровно того, что docs/RUNBOOK.md §2
# запрещает делать в этот час.
#
# Приоритет прежний, сквозной для всего CLI: флаг > конфиг > дефолт.
#
# rubocop:disable RSpec/DescribeClass -- сценарий CLI, а не класс
# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations -- каждый
# пример готовит файл и запускает отдельный процесс.
RSpec.describe 'bin/route --history' do
  let(:bin_route) { File.expand_path('../../bin/route', __dir__) }
  let(:queue_path) { reference_path('operations_queue_10.json') }
  let(:default_history) { reference_path('operations_history.csv') }

  def run_route(*args)
    Open3.capture3('ruby', bin_route, queue_path, *args)
  end

  def report(dir) = JSON.parse(File.read(File.join(dir, 'routing_report_test.json')))

  # История, где vipay не одобрил ничего: так рекомендации обязаны разойтись с
  # дефолтными, а не совпасть случайно.
  def write_history(path)
    CSV.open(path, 'w') do |csv|
      csv << %w[operation_id created_at amount bank card_brand payment_system status latency_sec]
      20.times do |index|
        csv << ["op_#{index}", '2026-07-29T08:00:00+03:00', 10_000, 'alfa', nil,
                'vipay', 'rejected', 30]
      end
    end
  end

  it 'на несуществующем файле падает с внятным сообщением, а не трейсом' do
    Dir.mktmpdir do |tmp|
      _stdout, stderr, status = run_route('--history', File.join(tmp, 'нет.csv'),
                                          '--out-dir', tmp)

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Файл истории операций не найден')
      expect(stderr).not_to include('backtrace')
    end
  end

  it 'с путём, равным конфигу, даёт побайтово тот же отчёт' do
    Dir.mktmpdir do |with_flag|
      Dir.mktmpdir do |without_flag|
        run_route('--history', default_history, '--out-dir', with_flag)
        run_route('--out-dir', without_flag)

        %w[routing_decisions_test.json routing_report_test.json].each do |name|
          expect(File.binread(File.join(with_flag, name)))
            .to eq(File.binread(File.join(without_flag, name)))
        end
      end
    end
  end

  it 'подменяет историю: рекомендации считаются по переданному файлу' do
    Dir.mktmpdir do |tmp|
      history = File.join(tmp, 'other_history.csv')
      write_history(history)

      _stdout, stderr, status = run_route('--history', history, '--out-dir', tmp)

      expect(status.exitstatus).to eq(0), stderr
      expect(report(tmp)['recommendations'].join(' ')).to include('vipay', '0/20')
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/ExampleLength, RSpec/MultipleExpectations
