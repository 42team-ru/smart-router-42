#!/usr/bin/env ruby
# frozen_string_literal: true

# Регресс-тесты гейтов и скоринга compare_competitors.rb.
# Загружает функции скрипта без запуска main и прогоняет синтетические отчёты.
#
#   ruby scripts/compare_competitors_selftest.rb

require 'json'
require 'set'

REPO_ROOT = File.expand_path('..', __dir__)
SCRIPT    = File.join(REPO_ROOT, 'scripts', 'compare_competitors.rb')
MARKER    = '# MAIN'

# Данные читаем до eval: скрипт переопределяет ROOT под себя.
local     = JSON.parse(File.read(File.join(REPO_ROOT, 'routing_report_test.json')))
decisions = JSON.parse(File.read(File.join(REPO_ROOT, 'routing_decisions_test.json')))

src = File.read(SCRIPT)
abort "В #{SCRIPT} не найден маркер '#{MARKER}' — тест не знает, где кончаются функции" \
  unless src.include?(MARKER)
$VERBOSE = nil
eval(src.split(MARKER).first, TOPLEVEL_BINDING) # rubocop:disable Security/Eval
CANON     = load_canonical_targets(local)
OUR_IDS   = decision_op_ids(decisions).to_set
REF_OPS   = extract_total_operations(local, OUR_IDS.size)

$failures = 0

def assess(report, decisions)
  m = build_metrics(repo: 'test', source: 'selftest', report: report, decisions: decisions,
                    canonical: CANON, our_op_ids: OUR_IDS)
  [m, comparability(m, REF_OPS), score(m)]
end

def expect(name, report, decisions, comparable:, tvd: :any)
  m, c, s = assess(report, decisions)
  ok = c[:comparable] == comparable && (tvd == :any || m[:count_tvd_pp] == tvd)
  $failures += 1 unless ok
  puts format('%-16s %s tvd=%-7s score=%-7s comparable=%-5s %s',
              ok ? '  ok' : '  FAIL', name.ljust(16), m[:count_tvd_pp].inspect,
              (s ? s[:value] : nil).inspect, c[:comparable], c[:reasons].join('; '))
end

def one_provider_decisions(decisions, provider)
  decisions.map { |d| { 'operation_id' => d['operation_id'], 'selected_provider' => provider } }
end

puts "Эталон: #{REF_OPS} операций\n\n"

# Нераспознанный формат не должен попадать в рейтинг с нулевым отклонением.
expect('empty-dist', { 'total_operations' => 90, 'foo' => 1 }, nil, comparable: false)
expect('array-report', [1, 2, 3], nil, comparable: false)
expect('foreign-names',
       { 'total_operations' => 90,
         'distribution' => { 'provider_a' => { 'share_pct' => 50 }, 'provider_b' => { 'share_pct' => 50 } } },
       nil, comparable: false)
expect('bad-shares-sum',
       { 'total_operations' => 90,
         'distribution' => { 'vipay' => { 'share_pct' => 40 }, 'payflow' => { 'share_pct' => 10 } } },
       nil, comparable: false)

# Несопоставимая выборка не должна занимать первое место идеальными долями.
expect('tiny-perfect',
       { 'total_operations' => 5,
         'distribution' => { 'vipay' => { 'share_pct' => 40, 'target_pct' => 40 },
                             'payflow' => { 'share_pct' => 35, 'target_pct' => 35 },
                             'quickpay' => { 'share_pct' => 25, 'target_pct' => 25 } } },
       nil, comparable: false)

# Вырожденные стратегии обязаны ранжироваться, а не выпадать из рейтинга.
expect('all-vipay', nil, one_provider_decisions(decisions, 'vipay'), comparable: true, tvd: 60.0)
expect('all-space', { 'total_operations' => 90 }, one_provider_decisions(decisions, 'spacepayments'),
       comparable: true, tvd: 100.0)

# Разнобой форматов: доли 0..1, проценты строкой, регистр и подчёркивания в именах.
expect('odd-format',
       { 'total_operations' => 90,
         'count_distribution' => { 'ViPay' => { 'share' => 0.40 }, 'Pay_Flow' => { 'share' => 0.35 },
                                   'QUICKPAY' => { 'share' => 0.25 } },
         'success_rate_pct' => '98,5%' },
       nil, comparable: true, tvd: 0.0)
expect('string-fallback',
       { 'total_operations' => 90, 'distribution' => local['distribution'],
         'fallback' => { 'fallback_rate_pct' => '12.5' } },
       nil, comparable: true)

# Наш собственный отчёт должен проходить все гейты.
expect('ours', local, decisions, comparable: true)

puts "\n#{$failures.zero? ? 'Все проверки пройдены' : "ПРОВАЛЕНО: #{$failures}"}"
exit($failures.zero? ? 0 : 1)
