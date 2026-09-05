#!/usr/bin/env ruby
# frozen_string_literal: true

# Сравнение конфигураций роутинга на синтетике.
#
#   scripts/bench_configs.rb                 все стратегии из реестра
#   scripts/bench_configs.rb config          все *.yml в каталоге, рекурсивно
#   scripts/bench_configs.rb a.yml b.yml     конкретные файлы
#
# Гоняет уровень compare (профиль competitive): у стратегии там есть реальный
# выбор почти на каждой заявке. На остальных уровнях допуск сужен намеренно —
# до 70% заявок имеют ровно одного кандидата, и любые конфиги дают там один и
# тот же результат.
#
# Таблица печатается отсюда, а не из bash: bash printf выравнивает по БАЙТАМ, и
# кириллические заголовки разъезжают колонки. Ruby format считает символы.

require 'json'
require 'open3'
require 'tmpdir'

ROOT = File.expand_path('..', __dir__)
Dir.chdir(ROOT)

LEVEL = 'compare'
SEED = ENV.fetch('SEED', '1')
DIR = File.join('tmp', 'bench', LEVEL)

COLUMNS = [
  ['конфиг', 22, :left],
  ['доставлено', 11, :right],
  ['fallback', 9, :right],
  ['макс.доля', 10, :right],
  ['откл.', 7, :right],
  ['ratio', 6, :right]
].freeze

LEGEND = <<~TEXT
  ─────────────────────────────────────────────────────────────────────────────
  доставлено  сколько заявок из %d проведено (approved + expired)
  fallback    сколько ушло в spacepayments — никто из внешних не подошёл
  макс.доля   доля крупнейшего провайдера: 90%% = «свалил почти всё одному»,
              ~20%% = распределил. Именно она различает стратегии нагляднее всего
  откл.       максимальное отклонение факта от целевой доли, в процентных пунктах
  ratio       во сколько раз хуже офлайн-эталона: 1.0 — не хуже идеала
  ─────────────────────────────────────────────────────────────────────────────
TEXT

def cell(value, width, align)
  text = value.to_s
  pad = [width - text.length, 0].max
  align == :left ? text + (' ' * pad) : (' ' * pad) + text
end

def row(values)
  COLUMNS.each_with_index.map { |(_, width, align), i| cell(values[i], width, align) }.join(' ')
end

def ensure_input
  return if File.exist?(File.join(DIR, 'queue.json'))

  system('bundle', 'exec', 'ruby', 'bin/gen', '--level', LEVEL, '--seed', SEED,
         '--out-dir', DIR, out: File::NULL) || abort('не удалось сгенерировать вход')
end

# Без аргументов — по конфигу на каждую зарегистрированную стратегию.
# Каталог разворачивается рекурсивно, файл берётся как есть.
def collect_configs(args, tmp)
  return strategy_configs(tmp) if args.empty?

  args.flat_map do |arg|
    File.directory?(arg) ? Dir.glob(File.join(arg, '**', '*.yml')) : [arg]
  end
end

def strategy_configs(tmp)
  names, = Open3.capture2('bundle', 'exec', 'ruby', '-e',
                          '$LOAD_PATH.unshift("lib"); require "routing/strategies"; ' \
                          'puts Routing::Strategies.load_all!')
  names.split.map do |name|
    path = File.join(tmp, "#{name}.yml")
    File.write(path, "strategy: #{name}\nlayers: []\nfallback_provider: spacepayments\n")
    path
  end
end

def run_config(path)
  out, = Open3.capture2e('bundle', 'exec', 'ruby', 'bin/bench', '--level', LEVEL,
                         '--seed', SEED, '--dir', DIR, '--config', path)
  out
end

# Ненулевой код выхода означает вердикт ПРОВАЛ, а не сбой запуска, поэтому
# ориентируемся на содержимое вывода: конфиг с необычным распределением обязан
# показать свои числа, а не исчезнуть из таблицы.
def parse_run(out)
  return nil unless out.include?('ВЕРДИКТ')

  {
    delivered: out[/доставлено: (\d+)/, 1],
    fallback: out[/(\d+) в spacepayments/, 1],
    deviation: out[/наш прогон: доставлено \d+, отклонение ([\d.]+)/, 1],
    ratio: out[/competitive_ratio: (\S+)/, 1]
  }
end

def max_share
  path = File.join(DIR, 'analytics.json')
  shares = JSON.parse(File.read(path))['distribution'].values.map { |v| v['share_pct'] }
  "#{shares.max}%"
end

def total_operations
  JSON.parse(File.read(File.join(DIR, 'analytics.json')))['total_operations']
end

def print_row(path, parsed)
  name = File.basename(path, '.yml')
  return puts(row([name, 'не запустился', '', '', '', ''])) if parsed.nil?

  puts row([name, parsed[:delivered], parsed[:fallback], max_share,
            parsed[:deviation] || '—', parsed[:ratio] || '—'])
end

ensure_input
Dir.mktmpdir do |tmp|
  configs = collect_configs(ARGV, tmp)
  abort('не найдено ни одного конфига') if configs.empty?

  puts "уровень #{LEVEL}, seed #{SEED}, конфигов: #{configs.size}"
  puts row(COLUMNS.map(&:first))
  configs.each { |path| print_row(path, parse_run(run_config(path))) }
  puts format(LEGEND, total_operations)
end
