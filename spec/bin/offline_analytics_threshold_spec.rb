# frozen_string_literal: true

require 'json'
require 'open3'
require 'tmpdir'

# Пакет 4: порог offline_analytics.max_operations гасит офлайн-эталон
# (Offline::Oracle) и офлайн-сравнение конфигураций (Offline::Comparison) на
# больших очередях -- обе части не влияют ни на одно решение, но вместе стоят
# ~70% времени полного прогона на 100 000 операций (см. комментарий у
# OFFLINE_ANALYTICS_MAX_OPS_DEFAULT в bin/route). Очередь в тестах всегда одна
# и та же (reference/data/operations_queue_10.json, 10 операций) -- порог
# двигаем конфигом, не размер очереди, иначе спек был бы медленным.
#
# rubocop:disable RSpec/DescribeClass -- bin/route исполняемый скрипт, а не класс
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength -- каждый сценарий
# готовит временный конфиг и проверяет связанный набор полей одного прогона
RSpec.describe 'bin/route: порог офлайн-аналитики' do
  let(:bin_route) { File.expand_path('../../bin/route', __dir__) }
  let(:queue_path) { reference_path('operations_queue_10.json') }
  let(:production_config) { File.expand_path('../../config/routing.yml', __dir__) }

  def run_route(*args)
    Open3.capture3('ruby', bin_route, *args)
  end

  # Заменяет весь блок offline_analytics: -- строка "offline_analytics:"
  # встречается в config/routing.yml один раз (плюс комментарий-документация
  # выше неё, но она не совпадает буквально с этим двухстрочным блоком).
  def config_with_max_ops(dir, max_ops)
    source = File.read(production_config)
    block = "offline_analytics:\n  max_operations: 10000\n"
    replacement = "offline_analytics:\n  max_operations: #{max_ops}\n"
    raise "блок #{block.inspect} исчез из config/routing.yml" unless source.include?(block)

    path = File.join(dir, 'routing.yml')
    File.write(path, source.sub(block, replacement))
    path
  end

  def report_for(dir)
    JSON.parse(File.read(File.join(dir, 'routing_report_test.json')))
  end

  it 'очередь ниже порога — benchmark и comparison присутствуют полноценно' do
    Dir.mktmpdir do |tmp|
      config = config_with_max_ops(tmp, 20)

      _stdout, stderr, status = run_route(queue_path, '--out-dir', tmp, '--config', config)
      report = report_for(tmp)

      expect(status.exitstatus).to eq(0), stderr
      expect(report['benchmark']['competitive_ratio']).not_to be_nil
      expect(report['benchmark']).not_to include('status')
      expect(report).to have_key('comparison')
      expect(report['comparison']['variants']).not_to be_empty
    end
  end

  it 'очередь выше порога — обе секции отсутствуют/помечены, отчёт остаётся валидным по ТЗ' do
    Dir.mktmpdir do |tmp|
      config = config_with_max_ops(tmp, 1)

      stdout, _stderr, status = run_route(queue_path, '--out-dir', tmp, '--config', config)
      report = report_for(tmp)

      expect(status.exitstatus).to eq(0)
      expect(stdout).to include('офлайн-аналитика').and include('пропущена')
      expect(report['benchmark']).to include(
        'status' => 'skipped_queue_too_large', 'total_operations' => 10, 'max_operations' => 1
      )
      expect(report['benchmark']['competitive_ratio']).to be_nil
      expect(report).not_to have_key('comparison')
      # Обязательная структура ТЗ (reference/TZ.md) не завязана на benchmark/comparison.
      expect(report).to include(
        'period', 'total_operations', 'distribution',
        'skip_reasons', 'projected_daily_utilization', 'recommendations'
      )
      expect(report['total_operations']).to eq(10)
    end
  end

  it '--offline-analytics перекрывает порог из конфига и считает аналитику' do
    Dir.mktmpdir do |tmp|
      config = config_with_max_ops(tmp, 1)

      _stdout, stderr, status = run_route(queue_path, '--out-dir', tmp, '--config', config,
                                          '--offline-analytics')
      report = report_for(tmp)

      expect(status.exitstatus).to eq(0), stderr
      expect(report['benchmark']['competitive_ratio']).not_to be_nil
      expect(report['benchmark']).not_to include('status')
      expect(report).to have_key('comparison')
    end
  end

  it '--no-offline-analytics перекрывает порог в обратную сторону и гасит аналитику' do
    Dir.mktmpdir do |tmp|
      config = config_with_max_ops(tmp, 20)

      stdout, _stderr, status = run_route(queue_path, '--out-dir', tmp, '--config', config,
                                          '--no-offline-analytics')
      report = report_for(tmp)

      expect(status.exitstatus).to eq(0)
      expect(stdout).to include('офлайн-аналитика').and include('пропущена')
      expect(report['benchmark']).to include('status' => 'skipped_queue_too_large')
      expect(report).not_to have_key('comparison')
    end
  end

  it 'решения (routing_decisions_test.json) не зависят от того, считалась ли аналитика' do
    Dir.mktmpdir do |tmp_enabled|
      Dir.mktmpdir do |tmp_skipped|
        enabled_config = config_with_max_ops(tmp_enabled, 20)
        skipped_config = config_with_max_ops(tmp_skipped, 1)

        run_route(queue_path, '--out-dir', tmp_enabled, '--config', enabled_config)
        run_route(queue_path, '--out-dir', tmp_skipped, '--config', skipped_config)

        enabled_decisions = File.binread(File.join(tmp_enabled, 'routing_decisions_test.json'))
        skipped_decisions = File.binread(File.join(tmp_skipped, 'routing_decisions_test.json'))

        expect(skipped_decisions).to eq(enabled_decisions)
      end
    end
  end

  it 'недопустимое значение offline_analytics.max_operations роняет запуск с понятным сообщением' do
    Dir.mktmpdir do |tmp|
      config = config_with_max_ops(tmp, '"десять"')

      _stdout, stderr, status = run_route(queue_path, '--out-dir', tmp, '--config', config)

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('offline_analytics.max_operations')
      expect(stderr).not_to include('backtrace')
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/ExampleLength
