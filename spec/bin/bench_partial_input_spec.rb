# frozen_string_literal: true

require 'open3'
require 'tmpdir'

# bin/bench сам генерирует вход, если его нет в каталоге. Проверка готовности
# смотрела только на очередь — а генерация пишет три файла подряд, и прерывание
# на полуслове (Ctrl-C, OOM, кончился диск) оставляет каталог с одной обрезанной
# queue.json.
#
# Такой каталог считался готовым: следующий запуск генерацию пропускал и падал
# на чтении expectation.json сообщением «No such file or directory», из которого
# причина не следует никак. Лечилось только ручным rm, о котором надо догадаться.
#
# Здесь ровно этот сценарий: кладём огрызок и ждём, что bin/bench его распознает,
# перегенерирует целиком и доедет до вердикта.
#
# rubocop:disable RSpec/DescribeClass -- сценарий CLI, а не класс
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength -- один прогон
# проверяется парой связанных утверждений: сообщение без успешного финала
# ничего не доказывает, а каждый пример готовит каталог и запускает процесс.
RSpec.describe 'bin/bench на неполном входе' do
  let(:bin_bench) { File.expand_path('../../bin/bench', __dir__) }

  def run_bench(dir)
    Open3.capture3('ruby', bin_bench, '--level', 'smoke', '--seed', '42', '--dir', dir)
  end

  it 'распознаёт огрызок прошлой генерации и перегенерирует вход целиком' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'queue.json'), '[{"operation_id":"op_1"')

      stdout, stderr, status = run_bench(dir)

      expect(status.exitstatus).to eq(0), stderr
      # Ход выполнения идёт в STDERR (Bench::Progress), отчёт — в STDOUT.
      expect(stderr).to include('неполный вход', 'queue.json')
      expect(stdout).to include('ВЕРДИКТ: OK')
    end
  end

  it 'на пустом каталоге сообщает про отсутствие входа, а не про огрызок' do
    Dir.mktmpdir do |dir|
      _stdout, stderr, status = run_bench(dir)

      expect(status.exitstatus).to eq(0), stderr
      expect(stderr).to include('генерация входа')
      expect(stderr).not_to include('неполный вход')
    end
  end

  it 'готовый вход второй раз не перегенерирует' do
    Dir.mktmpdir do |dir|
      run_bench(dir)

      stdout, stderr, status = run_bench(dir)

      expect(status.exitstatus).to eq(0), stdout
      expect(stderr).not_to include('генерация входа')
      expect(stderr).not_to include('неполный вход')
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/ExampleLength
