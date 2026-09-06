#!/usr/bin/env ruby
# frozen_string_literal: true

# Сравнение routing_report_test.json / routing_decisions_test.json с публичными
# репозиториями команд хакатона.
#
# Использование:
#   GITHUB_TOKEN=<token> ruby scripts/compare_competitors.rb
#   ruby scripts/compare_competitors.rb              # токен берётся из `gh auth token`
#   ruby scripts/compare_competitors.rb --json-only  # только JSON без Markdown
#   ruby scripts/compare_competitors.rb --no-search  # без code search, только KNOWN_REPOS
#   ruby scripts/compare_competitors.rb --no-network # только свой отчёт (самопроверка скрипта)
#
# Методика ранжирования — см. секцию «Скоринг» ниже и раздел «Методика» в отчёте.

require 'net/http'
require 'json'
require 'uri'
require 'base64'
require 'fileutils'
require 'time'

# --------------------------------------------------------------------------- #
# Конфигурация
# --------------------------------------------------------------------------- #

EXCLUDED_REPOS = [].freeze

# Репозитории GitHub, добавленные вручную — объединяются с результатами поиска.
# Те, у кого нет routing_report_test.json, молча пропускаются.
KNOWN_REPOS = %w[
  Agetosha/hackgenesis2026_smart_payment_routing
  TomYamTUSUR/Hack-Genesis
  s1rne/HackGenesis-2026
  temurysega/hack-ruby2
  camtimhamilton/hack_genesis
  Kemper5454/ruby-hack
  stasvinokur/hack_genesis_2026_solotech
  korowood/hack_genesis
  EdYaRdx/Ruby_hack
  gulldan/hackgenesis2026-public
  cajomitara/genesis-hackathon
  zoLikeCode/hack_genesis_routing
  alick-ai/pulseproof
].freeze

# Репозитории GitLab — загружаются отдельно через GitLab API.
KNOWN_GITLAB_REPOS = %w[
  denis-gordeev/ruby-hack
].freeze

ROOT            = File.expand_path('..', __dir__)
LOCAL_REPORT    = File.join(ROOT, 'routing_report_test.json')
LOCAL_DECISIONS = File.join(ROOT, 'routing_decisions_test.json')
OUTPUT_DIR      = File.join(ROOT, 'out', 'competitor_analysis')

GITHUB_TOKEN = (ENV['GITHUB_TOKEN'] || `gh auth token 2>/dev/null`.strip).freeze
GITLAB_TOKEN = ENV['GITLAB_TOKEN']

OUR_REPO = 'OUR/smart-router-42'

# Провайдеры с паспортными целями и аварийный fallback (цель 0).
PRIMARY_PROVIDERS  = %w[vipay payflow quickpay].freeze
FALLBACK_PROVIDERS = %w[spacepayments].freeze
ALL_PROVIDERS      = (PRIMARY_PROVIDERS + FALLBACK_PROVIDERS).freeze

# Паспортные цели — фолбэк, если команда их не указала в своём отчёте.
# Фактические значения берутся из нашего routing_report_test.json (см. load_canonical_targets).
DEFAULT_COUNT_TARGETS  = { 'vipay' => 40.0, 'payflow' => 35.0, 'quickpay' => 25.0, 'spacepayments' => 0.0 }.freeze
DEFAULT_VOLUME_TARGETS = { 'vipay' => 50.0, 'payflow' => 30.0, 'quickpay' => 20.0, 'spacepayments' => 0.0 }.freeze

# Веса композитного скора (меньше = лучше). Если компонент неизвестен —
# веса известных перенормируются, репо помечается как partial.
WEIGHTS = { count: 0.40, volume: 0.25, success_gap: 0.25, fallback: 0.10 }.freeze

# Гейт сопоставимости выборки: отклонение числа операций от нашей очереди.
SAMPLE_TOLERANCE_PCT  = 10.0
# Формат считаем распознанным, если найден хотя бы один известный провайдер
# и доли суммируются примерно в 100%. Вырожденная стратегия (всё в одного
# провайдера) — это плохая стратегия, а не нераспознанный формат: она обязана
# попасть в рейтинг и получить свой штраф, а не выпасть из него.
MIN_KNOWN_PROVIDERS = 1
SHARES_SUM_TOLERANCE_PCT = 5.0

FLAGS = {
  json_only:  ARGV.include?('--json-only'),
  no_search:  ARGV.include?('--no-search'),
  no_network: ARGV.include?('--no-network')
}.freeze

# --------------------------------------------------------------------------- #
# Утилиты
# --------------------------------------------------------------------------- #

def to_f_or_nil(v)
  return nil if v.nil?
  return v.to_f if v.is_a?(Numeric)
  s = v.to_s.strip.delete('%').tr(',', '.')
  return nil if s.empty?
  Float(s)
rescue ArgumentError, TypeError
  nil
end

# vipay / VIPay / space_payments -> vipay / spacepayments
def norm_prov(key)
  key.to_s.strip.downcase.gsub(/[^a-z0-9]/, '')
end

def dig_first(hash, *paths)
  paths.each do |path|
    v = path.reduce(hash) { |h, k| h.is_a?(Hash) ? h[k] : nil }
    return v unless v.nil?
  end
  nil
end

def round2(v)
  v.nil? ? nil : v.round(2)
end

# Доли могут быть заданы как 0..1 вместо 0..100 — чиним по сумме.
def rescale_shares!(shares)
  vals = shares.values.compact
  return shares if vals.empty?
  sum = vals.sum
  shares.transform_values! { |v| v && v * 100.0 } if sum > 0.5 && sum <= 1.5
  shares
end

# --------------------------------------------------------------------------- #
# GitHub API
# --------------------------------------------------------------------------- #

def github_headers
  h = {
    'Accept'     => 'application/vnd.github.v3+json',
    'User-Agent' => 'smart-router-42-compare/2.0'
  }
  h['Authorization'] = "Bearer #{GITHUB_TOKEN}" unless GITHUB_TOKEN.empty?
  h
end

def github_get(url, retries: 2)
  uri = URI(url)
  Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 15) do |http|
    res = http.request(Net::HTTP::Get.new(uri, github_headers))
    case res.code
    when '200' then JSON.parse(res.body)
    when '403', '429'
      raise "Rate limited (#{res.code}). Установите GITHUB_TOKEN или подождите."
    when '404'
      nil
    else
      raise "GitHub API #{res.code}: #{res.body[0..120]}"
    end
  end
rescue Net::ReadTimeout, Errno::ECONNRESET => e
  retries -= 1
  retry if retries >= 0
  warn "  Timeout: #{e.message}"
  nil
rescue StandardError => e
  warn "  HTTP error: #{e.message}"
  nil
end

def search_one(query, max_pages: 3)
  repos = []
  (1..max_pages).each do |page|
    data = github_get(
      "https://api.github.com/search/code" \
      "?q=#{URI.encode_www_form_component(query)}" \
      "&per_page=30&page=#{page}"
    )
    break unless data
    items = data['items'] || []
    items.each { |item| repos << item['repository']['full_name'] }
    break if items.size < 30
    sleep 1.5
  end
  repos
rescue StandardError => e
  warn "  Ошибка поиска '#{query}': #{e.message}"
  []
end

def search_all_repos
  queries = [
    'filename:routing_report_test.json',
    'filename:routing_decisions_test.json',
    '"routing_report_test" extension:json',
    '"selected_provider" "operation_id" filename:routing_decisions_test.json',
    '"deviation_pp" "target_pct" extension:json',
    '"vipay" "payflow" "quickpay" filename:routing_report_test.json',
    '"spacepayments" "count_share" extension:json'
  ]

  found = []
  queries.each do |q|
    print "  Запрос: #{q[0..60]}... "
    before = found.size
    found = (found + search_one(q)).uniq
    puts "+#{found.size - before} (итого #{found.size})"
    sleep 1.0
  end
  found
end

def fetch_json_file(owner, repo, path)
  data = github_get("https://api.github.com/repos/#{owner}/#{repo}/contents/#{path}")
  return nil unless data && data['content']
  JSON.parse(Base64.decode64(data['content']).force_encoding('UTF-8'))
rescue JSON::ParserError => e
  warn "  Некорректный JSON #{owner}/#{repo}/#{path}: #{e.message}"
  nil
rescue StandardError => e
  warn "  Не удалось получить #{owner}/#{repo}/#{path}: #{e.message}"
  nil
end

# --------------------------------------------------------------------------- #
# GitLab API
# --------------------------------------------------------------------------- #

def fetch_gitlab_json_file(namespace_path, path, ref: 'main')
  url = "https://gitlab.com/api/v4/projects/#{URI.encode_www_form_component(namespace_path)}" \
        "/repository/files/#{URI.encode_www_form_component(path)}/raw?ref=#{ref}"
  uri = URI(url)
  headers = { 'User-Agent' => 'smart-router-42-compare/2.0' }
  headers['PRIVATE-TOKEN'] = GITLAB_TOKEN if GITLAB_TOKEN
  raw = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 15) do |http|
    res = http.request(Net::HTTP::Get.new(uri, headers))
    return nil if %w[404 403].include?(res.code)
    raise "GitLab #{res.code}" unless res.code == '200'
    res.body
  end
  JSON.parse(raw.force_encoding('UTF-8'))
rescue JSON::ParserError => e
  warn "  Некорректный JSON GitLab #{namespace_path}/#{path}: #{e.message}"
  nil
rescue StandardError => e
  warn "  Не удалось получить GitLab #{namespace_path}/#{path}: #{e.message}"
  nil
end

# --------------------------------------------------------------------------- #
# Цели: берём из своего отчёта, при отсутствии — паспортные константы
# --------------------------------------------------------------------------- #

def load_canonical_targets(local_report)
  count  = DEFAULT_COUNT_TARGETS.dup
  volume = DEFAULT_VOLUME_TARGETS.dup
  (local_report['distribution'] || {}).each do |k, v|
    t = v.is_a?(Hash) ? to_f_or_nil(v['target_pct']) : nil
    count[norm_prov(k)] = t if t
  end
  (local_report['volume_distribution'] || {}).each do |k, v|
    t = v.is_a?(Hash) ? to_f_or_nil(v['target_pct']) : nil
    volume[norm_prov(k)] = t if t
  end
  [count.freeze, volume.freeze]
end

# --------------------------------------------------------------------------- #
# Извлечение распределений (нормализует форматы разных команд)
# --------------------------------------------------------------------------- #

# Общий разбор блока distribution: provider => {share_pct, target_pct, achievable_pct, claimed_dev_pp, raw}
def parse_distribution(node, kind, total_hint)
  return nil unless node.is_a?(Hash) && !node.empty?

  raw_amount_keys = kind == :volume ? %w[amount volume total_amount sum] : %w[count operations ops n]
  share_keys      = kind == :volume ? %w[share_pct amount_share_pct volume_share_pct share percentage pct]
                                    : %w[share_pct count_share_pct share percentage pct]

  entries = {}
  node.each do |k, v|
    prov = norm_prov(k)
    next if prov.empty?
    if v.is_a?(Numeric)
      entries[prov] = { amount: v.to_f, share_pct: nil, target_pct: nil, achievable_pct: nil, claimed_dev_pp: nil }
      next
    end
    next unless v.is_a?(Hash)
    entries[prov] = {
      amount:         raw_amount_keys.filter_map { |kk| to_f_or_nil(v[kk]) }.first,
      share_pct:      share_keys.filter_map { |kk| to_f_or_nil(v[kk]) }.first,
      target_pct:     %w[target_pct target target_share_pct].filter_map { |kk| to_f_or_nil(v[kk]) }.first,
      achievable_pct: %w[achievable_pct achievable achievable_share_pct feasible_pct]
                        .filter_map { |kk| to_f_or_nil(v[kk]) }.first,
      claimed_dev_pp: %w[deviation_pp delta_pp deviation_pct deviation_pct_points delta_pct]
                        .filter_map { |kk| to_f_or_nil(v[kk]) }.first
    }
  end
  return nil if entries.empty?

  # share из amount/count, если долей нет
  if entries.values.all? { |e| e[:share_pct].nil? }
    total = entries.values.filter_map { |e| e[:amount] }.sum
    total = total_hint if total.zero? && total_hint&.positive?
    if total&.positive?
      entries.each { |_, e| e[:share_pct] = e[:amount] ? (e[:amount] / total * 100.0) : nil }
    end
  end

  shares = entries.transform_values { |e| e[:share_pct] }
  rescale_shares!(shares)
  entries.each { |p, e| e[:share_pct] = shares[p] }
  entries
end

def report_count_distribution(report, total_hint)
  node = report['distribution'] || report['count_distribution'] ||
         dig_first(report, %w[distributions count], %w[shares count])
  parse_distribution(node, :count, total_hint)
end

def report_volume_distribution(report, total_hint)
  node = report['volume_distribution'] || report['amount_distribution'] ||
         dig_first(report, %w[distributions volume], %w[shares volume])
  parse_distribution(node, :volume, total_hint)
end

# Распределение прямо из решений — не зависит от формата чужого отчёта.
def distribution_from_decisions(decisions)
  return nil unless decisions.is_a?(Array) && !decisions.empty?
  provs = decisions.filter_map do |d|
    next unless d.is_a?(Hash)
    p = d['selected_provider'] || d['provider'] || d['chosen_provider'] ||
        dig_first(d, %w[decision provider], %w[result provider])
    p = norm_prov(p)
    p.empty? ? nil : p
  end
  return nil if provs.empty?

  tally = provs.tally
  total = tally.values.sum.to_f
  tally.each_with_object({}) do |(p, c), h|
    h[p] = { amount: c.to_f, share_pct: c / total * 100.0,
             target_pct: nil, achievable_pct: nil, claimed_dev_pp: nil }
  end
end

def decision_op_ids(decisions)
  return nil unless decisions.is_a?(Array)
  ids = decisions.filter_map { |d| d.is_a?(Hash) ? (d['operation_id'] || d['id']) : nil }
  ids.empty? ? nil : ids
end

# --------------------------------------------------------------------------- #
# Отклонения
# --------------------------------------------------------------------------- #

# Total variation distance в п.п.: 0.5 * сумма модулей отклонений по всем провайдерам.
# Учитывает и недобор, и перебор, и «левых» провайдеров вне паспорта.
def deviation_stats(entries, canonical_targets, base: :target)
  return nil unless entries

  provs = (canonical_targets.keys + entries.keys).uniq
  rows  = provs.filter_map do |p|
    e     = entries[p]
    share = e ? e[:share_pct] : 0.0
    next if share.nil?
    target =
      case base
      when :achievable then (e && e[:achievable_pct]) || (e && e[:target_pct]) || canonical_targets[p]
      else                  (e && e[:target_pct]) || canonical_targets[p]
      end
    next if target.nil?
    { provider: p, share_pct: share.round(2), target_pct: target.round(2),
      deviation_pp: (share - target).round(2) }
  end
  return nil if rows.empty?

  {
    rows:               rows,
    providers_matched:  rows.count { |r| entries.key?(r[:provider]) },
    known_providers_present: ALL_PROVIDERS.count { |p| entries.key?(p) },
    shares_sum_pct:     entries.values.filter_map { |e| e[:share_pct] }.sum.round(2),
    tvd_pp:             (rows.sum { |r| r[:deviation_pp].abs } / 2.0).round(2),
    l1_pp:              rows.sum { |r| r[:deviation_pp].abs }.round(2),
    max_deviation_pp:   rows.map { |r| r[:deviation_pp].abs }.max.round(2),
    off_target_share_pct: FALLBACK_PROVIDERS.sum { |p| entries.dig(p, :share_pct) || 0.0 }.round(2)
  }
end

# --------------------------------------------------------------------------- #
# Прочие метрики отчёта
# --------------------------------------------------------------------------- #

# Возвращает [значение, источник] — источник нужен, чтобы видеть,
# что колонка Success% собрана из разных по смыслу полей.
def extract_success_rate(report, total_ops)
  outcomes = report['outcomes_summary'] || report['outcomes'] || report['simulated_results'] || {}
  outcomes = {} unless outcomes.is_a?(Hash)

  candidates = [
    ['outcomes.success_rate_pct',   to_f_or_nil(outcomes['success_rate_pct'])],
    ['outcomes.approval_rate_pct',  to_f_or_nil(outcomes['approval_rate_pct'])],
    ['report.success_rate_pct',     to_f_or_nil(report['success_rate_pct'])],
    ['results.approval_rate_pct',   to_f_or_nil(report.is_a?(Hash) ? dig_first(report, %w[results approval_rate_pct]) : nil)],
    ['outcomes.end_to_end_success_rate', to_f_or_nil(outcomes['end_to_end_success_rate'])]
  ]
  name, val = candidates.find { |_, v| !v.nil? }

  if val.nil?
    approved = to_f_or_nil(
      (outcomes['approved'].is_a?(Hash) ? outcomes['approved']['count'] : outcomes['approved']) ||
      dig_first(report, %w[results approved], %w[routing_quality approved],
                %w[status_summary approved count], %w[status_summary approved])
    )
    if approved.nil? && report['results'].is_a?(Hash)
      s = report['results'].values.sum { |v| v.is_a?(Hash) ? (to_f_or_nil(v['approved']) || 0.0) : 0.0 }
      approved = s.positive? ? s : nil
    end
    if approved && total_ops&.positive?
      val  = approved / total_ops * 100.0
      name = 'derived: approved/total'
    end
  end
  return [nil, nil] if val.nil?

  # доля 0..1 вместо процентов
  if val <= 1.0 && val.positive?
    val *= 100.0
    name = "#{name} (×100)"
  end
  return [nil, "#{name}: вне диапазона (#{val.round(1)})"] if val.negative? || val > 100.5
  [val.round(2), name]
end

def extract_fallback(report, total_ops)
  outcomes = report['outcomes_summary'] || report['outcomes'] || {}
  outcomes = {} unless outcomes.is_a?(Hash)

  ops = to_f_or_nil(
    dig_first(report,
              %w[fallback recovered_by_fallback], %w[fallback count], %w[fallback_count],
              %w[routing_kpis fallback_operations], %w[routing_resilience fallback_count],
              %w[routing_quality fallback_count]) || outcomes['fallback_triggered']
  )

  rate = to_f_or_nil(
    dig_first(report,
              %w[fallback fallback_rate_pct], %w[fallback share_pct],
              %w[fallback_usage share_pct], %w[routing_resilience fallback_share_pct])
  )
  rate = (ops / total_ops * 100.0) if rate.nil? && ops && total_ops&.positive?
  rate *= 100.0 if rate && rate <= 1.0 && rate.positive? && ops && total_ops&.positive? && (ops / total_ops) > 0.015
  [ops&.round(0)&.to_i, rate && rate.round(2)]
end

def extract_coverage(report, decisions_count, total_ops)
  qc = report['queue_coverage'] || report['routing_coverage'] || {}
  qc = {} unless qc.is_a?(Hash)
  cov = to_f_or_nil(qc['coverage_pct'] || qc['decision_coverage_pct'])
  return cov.round(2) if cov
  # Ни в коем случае не 100 по умолчанию: считаем из решений или оставляем nil.
  return (decisions_count / total_ops.to_f * 100.0).round(2) if decisions_count && total_ops&.positive?
  nil
end

def extract_total_operations(report, decisions_count)
  to_f_or_nil(
    report['total_operations'] ||
    dig_first(report, %w[queue_coverage queue_operations], %w[summary total_operations],
              %w[routing_coverage queue_operations]) ||
    report['operations_count']
  )&.round&.to_i || decisions_count
end

# --------------------------------------------------------------------------- #
# Сборка метрик
# --------------------------------------------------------------------------- #

def build_metrics(repo:, source:, report:, decisions:, canonical:, our_op_ids:)
  warnings = []
  report   = {} unless report.is_a?(Hash)
  warnings << 'отчёт не является JSON-объектом' if report.empty?

  op_ids          = decision_op_ids(decisions)
  decisions_count = op_ids&.size
  total_ops       = extract_total_operations(report, decisions_count)

  count_targets, volume_targets = canonical

  # Выборка: сверяем множество operation_id с нашим.
  sample_match =
    if op_ids.nil?                     then :unknown
    elsif op_ids.to_set == our_op_ids  then :exact
    else :partial
    end

  # Приоритет источника count-распределения: решения (формато-независимо) > отчёт.
  from_decisions = distribution_from_decisions(decisions)
  from_report    = report_count_distribution(report, total_ops)

  if from_decisions && sample_match == :exact
    count_entries = from_decisions
    dist_source   = 'decisions'
    # цели/achievable подмешиваем из отчёта, если они там есть
    (from_report || {}).each do |p, e|
      next unless count_entries[p]
      count_entries[p][:target_pct]     ||= e[:target_pct]
      count_entries[p][:achievable_pct] ||= e[:achievable_pct]
      count_entries[p][:claimed_dev_pp] ||= e[:claimed_dev_pp]
    end
  elsif from_report
    count_entries = from_report
    dist_source   = 'report'
    warnings << 'решения не совпали с нашей очередью, count-доли взяты из отчёта' if from_decisions
  elsif from_decisions
    count_entries = from_decisions
    dist_source   = 'decisions (выборка отличается)'
  else
    count_entries = nil
    dist_source   = nil
    warnings << 'не удалось распознать count-распределение'
  end

  volume_entries = report_volume_distribution(report, nil)
  warnings << 'нет volume-распределения' if volume_entries.nil?

  count_dev      = deviation_stats(count_entries, count_targets, base: :target)
  count_dev_ach  = deviation_stats(count_entries, count_targets, base: :achievable)
  volume_dev     = deviation_stats(volume_entries, volume_targets, base: :target)

  success_rate, success_src = extract_success_rate(report, total_ops)
  warnings << "success_rate не извлечён (#{success_src})" if success_rate.nil? && success_src
  warnings << 'success_rate не найден ни в одном известном поле' if success_rate.nil? && success_src.nil?

  fallback_ops, fallback_rate = extract_fallback(report, total_ops)
  coverage = extract_coverage(report, decisions_count, total_ops)
  warnings << "coverage #{coverage}% < 100" if coverage && coverage < 99.95

  feasibility = report['target_feasibility']
  declares_infeasible =
    if feasibility.is_a?(Hash)
      feasibility.values.any? { |v| v.is_a?(Hash) && v['feasible'] == false }
    elsif count_entries
      count_entries.any? { |_, e| e[:achievable_pct] && e[:target_pct] && (e[:achievable_pct] - e[:target_pct]).abs > 0.05 }
    end

  providers_matched = count_dev ? count_dev[:providers_matched] : 0
  known_present     = count_dev ? count_dev[:known_providers_present] : 0
  shares_sum        = count_dev && count_dev[:shares_sum_pct]
  format_ok         = count_dev &&
                      known_present >= MIN_KNOWN_PROVIDERS &&
                      shares_sum && (shares_sum - 100.0).abs <= SHARES_SUM_TOLERANCE_PCT
  warnings << "доли не суммируются в 100% (#{shares_sum})" if count_dev && !format_ok && known_present.positive?
  warnings << 'ни один известный провайдер не найден в распределении' if count_dev && known_present.zero?

  {
    repo: repo,
    source: source,
    strategy: report['strategy'] || report['strategy_profile'] || dig_first(report, %w[policy name]),
    total_operations: total_ops,
    decisions_count: decisions_count,
    sample_match: sample_match,
    dist_source: dist_source,
    providers_matched: providers_matched,
    known_providers_present: known_present,
    shares_sum_pct: shares_sum,
    format_recognized: !!format_ok,

    count_tvd_pp:            count_dev && count_dev[:tvd_pp],
    count_l1_pp:             count_dev && count_dev[:l1_pp],
    count_max_dev_pp:        count_dev && count_dev[:max_deviation_pp],
    count_max_dev_vs_achievable_pp: count_dev_ach && count_dev_ach[:max_deviation_pp],
    count_rows:              count_dev && count_dev[:rows],
    off_target_share_pct:    count_dev && count_dev[:off_target_share_pct],

    volume_tvd_pp:           volume_dev && volume_dev[:tvd_pp],
    volume_max_dev_pp:       volume_dev && volume_dev[:max_deviation_pp],
    volume_rows:             volume_dev && volume_dev[:rows],

    success_rate_pct:        success_rate,
    success_rate_source:     success_src,
    fallback_ops:            fallback_ops,
    fallback_rate_pct:       fallback_rate,
    queue_coverage_pct:      coverage,
    declares_infeasible_targets: declares_infeasible,

    cost_efficiency_vs_best_pct: to_f_or_nil(dig_first(report, %w[cost_efficiency vs_best_pct])),
    margin_earned:               to_f_or_nil(dig_first(report, %w[cost_efficiency margin_earned])),
    benchmark_competitive_ratio: to_f_or_nil(dig_first(report, %w[benchmark competitive_ratio])),

    warnings: warnings
  }
end

# --------------------------------------------------------------------------- #
# Скоринг и гейт сопоставимости
# --------------------------------------------------------------------------- #

def comparability(metrics, reference_ops)
  reasons = []
  if metrics[:count_tvd_pp].nil?
    reasons << 'нет count-распределения'
  elsif !metrics[:format_recognized]
    reasons << "формат не распознан (известных провайдеров: #{metrics[:known_providers_present]}, " \
               "сумма долей: #{metrics[:shares_sum_pct]}%)"
  end

  ops = metrics[:total_operations]
  if ops.nil? || ops.zero?
    reasons << 'неизвестен размер выборки'
  elsif reference_ops&.positive?
    diff_pct = (ops - reference_ops).abs / reference_ops.to_f * 100.0
    reasons << "выборка #{ops} оп. против нашей #{reference_ops} (±#{diff_pct.round(1)}%)" \
      if diff_pct > SAMPLE_TOLERANCE_PCT
  end

  { comparable: reasons.empty?, reasons: reasons }
end

def score_components(metrics)
  # Все компоненты — штрафы в п.п., 0 = идеально.
  {
    count:        metrics[:count_tvd_pp],
    volume:       metrics[:volume_tvd_pp],
    success_gap:  metrics[:success_rate_pct] && (100.0 - metrics[:success_rate_pct]),
    fallback:     metrics[:fallback_rate_pct]
  }
end

# only: ограничить набор компонентов (строгий ранг по общему знаменателю).
def score(metrics, only: nil)
  components = score_components(metrics)
  components = components.slice(*only) if only
  known = components.reject { |_, v| v.nil? }
  return nil if known.empty? || known[:count].nil?

  wsum  = known.keys.sum { |k| WEIGHTS[k] }
  total = known.sum { |k, v| WEIGHTS[k] * v } / wsum

  {
    value:      total.round(3),
    partial:    known.size < components.size,
    missing:    components.select { |_, v| v.nil? }.keys,
    components: components.transform_values { |v| v && v.round(2) },
    weights_used: known.keys.to_h { |k| [k, (WEIGHTS[k] / wsum).round(3)] }
  }
end

# --------------------------------------------------------------------------- #
# Сравнение решений пооперационно
# --------------------------------------------------------------------------- #

def compare_decisions(local_arr, competitor_arr)
  return nil unless local_arr.is_a?(Array) && competitor_arr.is_a?(Array)

  pick = lambda do |d|
    next nil unless d.is_a?(Hash)
    p = d['selected_provider'] || d['provider'] || d['chosen_provider'] ||
        dig_first(d, %w[decision provider], %w[result provider])
    p.nil? ? nil : norm_prov(p)
  end

  local_map = local_arr.each_with_object({}) { |d, h| h[d['operation_id']] = pick.(d) }
  comp_map  = competitor_arr.each_with_object({}) { |d, h| h[d['operation_id'] || d['id']] = pick.(d) }
  common    = local_map.keys & comp_map.keys
  return nil if common.empty?

  matches    = common.count { |op| local_map[op] == comp_map[op] }
  mismatches = common.reject { |op| local_map[op] == comp_map[op] }
                     .map { |op| { operation_id: op, ours: local_map[op], theirs: comp_map[op] } }

  {
    common_operations:  common.size,
    coverage_of_ours:   (common.size.to_f / local_map.size * 100).round(1),
    matching_decisions: matches,
    match_rate_pct:     (matches.to_f / common.size * 100).round(1),
    provider_frequency: comp_map.values.compact.tally.sort_by { |_, c| -c }.to_h,
    mismatches_sample:  mismatches.first(10)
  }
end

# --------------------------------------------------------------------------- #
# Рендеринг
# --------------------------------------------------------------------------- #

def fmt(v, suffix = '')
  v.nil? ? '—' : "#{v}#{suffix}"
end

def render_markdown(results, ranked, unranked, generated_at, reference_ops, strict_components)
  strict_label = strict_components.empty? ? 'нет общих компонентов' : strict_components.join(', ')
  l = []
  l << '# Сравнение конкурентов — routing_report_test'
  l << ''
  l << "_Сгенерировано: #{generated_at.strftime('%Y-%m-%d %H:%M UTC')}. Эталонная очередь: #{reference_ops} операций._"
  l << ''
  l << '## Методика'
  l << ''
  l << '- **Score** (меньше = лучше) — взвешенная сумма: ' \
       "count #{WEIGHTS[:count]}, volume #{WEIGHTS[:volume]}, success_gap #{WEIGHTS[:success_gap]}, fallback #{WEIGHTS[:fallback]}. " \
       'Все компоненты — штрафы в п.п., 0 = идеально (success_gap = 100 − success_rate). ' \
       'Если компонента нет — веса остальных перенормируются, строка помечается `partial`.'
  l << '- **Основной ранг — `Score*` (strict)**: считается по компонентам, доступным у ВСЕХ ранжируемых репо ' \
       '(в этом прогоне: ' + strict_label + '). Полный `Score` даётся справочно: между строками с разным ' \
       'набором данных он несопоставим — команда без volume-отчёта иначе выигрывает за счёт отсутствия данных.'
  l << '- **TVD** (total variation distance, п.п.) = ½·Σ|share − target| по всем провайдерам, включая ' \
       'сверхлимитных и `spacepayments` (цель 0). В отличие от max-отклонения учитывает все перекосы, а не худший.'
  l << '- **База отклонения** — паспортный `target`. Колонка `MaxDev/ach` показывает то же от `achievable`: ' \
       'команда, честно упирающаяся в ограничения банков и лимитов, будет хуже по target и лучше по achievable.'
  l << '- **Count-доли берутся из `routing_decisions_test.json`**, когда набор `operation_id` совпадает с нашим — ' \
       'это не зависит от формата чужого отчёта. Источник указан в колонке `Dist`.'
  l << '- В ранг попадают только сопоставимые репо: распознан формат (есть известные провайдеры, доли ≈100%) ' \
       "и размер выборки в пределах ±#{SAMPLE_TOLERANCE_PCT}% от нашей. Остальные — в секции ниже, без места. " \
       'Вырожденная стратегия (всё одному провайдеру) ранжируется как плохая, а не выпадает из рейтинга.'
  l << '- `Success%` собран из разных полей у разных команд (источник указан в деталях) — метрика справочная.'
  l << ''
  l << '## Рейтинг (score, меньше = лучше)'
  l << ''
  l << '| # | Репозиторий | Score* | Score (полный) | Count TVD | Vol TVD | MaxDev/target | MaxDev/ach | Success% | Fallback% | Ops | Dist | Флаги |'
  l << '|---|---|---|---|---|---|---|---|---|---|---|---|---|'

  ranked.each do |r|
    m = r[:metrics]
    s = r[:score]
    flags = []
    flags << 'partial' if s && s[:partial]
    flags << 'infeasible-targets' if m[:declares_infeasible_targets]
    flags << "off-target #{m[:off_target_share_pct]}%" if m[:off_target_share_pct]&.positive?
    flags << "coverage #{m[:queue_coverage_pct]}%" if m[:queue_coverage_pct] && m[:queue_coverage_pct] < 99.95
    label = r[:repo] + (r[:repo] == OUR_REPO ? ' ← **МЫ**' : '')
    st = r[:score_strict]
    l << "| #{r[:rank]} | #{label} | **#{st ? st[:value] : '—'}** | #{s ? s[:value] : '—'} | #{fmt m[:count_tvd_pp]} | #{fmt m[:volume_tvd_pp]} | " \
         "#{fmt m[:count_max_dev_pp]} | #{fmt m[:count_max_dev_vs_achievable_pp]} | #{fmt m[:success_rate_pct]} | " \
         "#{fmt m[:fallback_rate_pct]} | #{fmt m[:total_operations]} | #{fmt m[:dist_source]} | #{flags.join(', ')} |"
  end

  unless unranked.empty?
    l << ''
    l << '## Вне рейтинга (несопоставимые)'
    l << ''
    l << '| Репозиторий | Причина | Ops | Count TVD (справочно) |'
    l << '|---|---|---|---|'
    unranked.each do |r|
      l << "| #{r[:repo]} | #{r[:comparability][:reasons].join('; ')} | " \
           "#{fmt r[:metrics][:total_operations]} | #{fmt r[:metrics][:count_tvd_pp]} |"
    end
  end

  l << ''
  l << '## Детали по репозиториям'

  results.each do |entry|
    m  = entry[:metrics]
    s  = entry[:score]
    dc = entry[:decisions_vs_ours]
    l << ''
    l << "### #{entry[:repo]}#{entry[:repo] == OUR_REPO ? ' ← МЫ' : ''}"
    l << ''
    l << "- **Источник**: #{m[:source]}"
    l << "- **Операций**: #{fmt m[:total_operations]} (решений: #{fmt m[:decisions_count]}, выборка: #{m[:sample_match]})"
    l << "- **Стратегия**: `#{m[:strategy] || '—'}`"
    l << "- **Coverage**: #{fmt m[:queue_coverage_pct], '%'}"
    l << "- **Score**: #{s ? s[:value] : '—'}" + (s ? " (#{s[:components].map { |k, v| "#{k}=#{fmt v}" }.join(', ')}" \
         "#{s[:partial] ? "; нет: #{s[:missing].join(', ')}" : ''})" : '')
    l << "- **Success**: #{fmt m[:success_rate_pct], '%'} (источник: #{m[:success_rate_source] || '—'})"
    l << "- **Fallback**: #{fmt m[:fallback_ops]} ops (#{fmt m[:fallback_rate_pct], '%'})"
    l << "- **Margin vs best**: #{m[:cost_efficiency_vs_best_pct]}%" if m[:cost_efficiency_vs_best_pct]
    l << "- **Competitive ratio**: #{m[:benchmark_competitive_ratio]}" if m[:benchmark_competitive_ratio]
    l << "- **Заявляет недостижимые цели**: #{m[:declares_infeasible_targets] ? 'да' : 'нет'}"
    unless entry[:comparability][:comparable]
      l << "- **Вне рейтинга**: #{entry[:comparability][:reasons].join('; ')}"
    end
    unless m[:warnings].empty?
      l << "- **Замечания**: #{m[:warnings].join('; ')}"
    end

    if m[:count_rows]
      l << ''
      l << "**Count-share (источник: #{m[:dist_source]}):**"
      l << ''
      l << '| Provider | Share% | Target% | Dev (pp) |'
      l << '|---|---|---|---|'
      m[:count_rows].each { |r| l << "| #{r[:provider]} | #{r[:share_pct]} | #{r[:target_pct]} | #{r[:deviation_pp]} |" }
    end

    if m[:volume_rows]
      l << ''
      l << '**Volume-share:**'
      l << ''
      l << '| Provider | Share% | Target% | Dev (pp) |'
      l << '|---|---|---|---|'
      m[:volume_rows].each { |r| l << "| #{r[:provider]} | #{r[:share_pct]} | #{r[:target_pct]} | #{r[:deviation_pp]} |" }
    end

    next unless dc
    l << ''
    l << '**Сравнение решений с нашими** (похожесть, не качество):'
    l << "- Общих операций: #{dc[:common_operations]} (#{dc[:coverage_of_ours]}% нашей очереди)"
    l << "- Совпали: #{dc[:matching_decisions]} (#{dc[:match_rate_pct]}%)"
    l << "- Частота провайдеров: #{dc[:provider_frequency].map { |k, v| "#{k}=#{v}" }.join(', ')}"
    next if dc[:mismatches_sample].empty?
    l << "- Примеры расхождений (первые #{dc[:mismatches_sample].size}):"
    dc[:mismatches_sample].each { |mm| l << "  - `#{mm[:operation_id]}`: они → **#{mm[:theirs]}**, мы → #{mm[:ours]}" }
  end

  l << ''
  l << '---'
  l << "_Excluded: #{EXCLUDED_REPOS.empty? ? '—' : EXCLUDED_REPOS.join(', ')}_"
  l.join("\n")
end

# --------------------------------------------------------------------------- #
# MAIN
# --------------------------------------------------------------------------- #

require 'set'

FileUtils.mkdir_p(OUTPUT_DIR)

local_report    = JSON.parse(File.read(LOCAL_REPORT))
local_decisions = JSON.parse(File.read(LOCAL_DECISIONS))
canonical       = load_canonical_targets(local_report)
our_op_ids      = (decision_op_ids(local_decisions) || []).to_set
reference_ops   = extract_total_operations(local_report, our_op_ids.size)

puts '=== Сравнение конкурентов ==='
puts "Эталон: #{reference_ops} операций, цели count=#{canonical[0].select { |k, _| ALL_PROVIDERS.include?(k) }}"

competitors = []
unless FLAGS[:no_network]
  found = FLAGS[:no_search] ? [] : (puts 'Поиск репозиториев на GitHub...'; search_all_repos)
  puts "Найдено через поиск: #{found.size}"
  competitors = (found + KNOWN_REPOS).uniq - EXCLUDED_REPOS
  puts "К обработке: #{competitors.size}"
end

results = []

process = lambda do |repo, source, report, decisions|
  metrics = build_metrics(repo: repo, source: source, report: report, decisions: decisions,
                          canonical: canonical, our_op_ids: our_op_ids)
  comp    = comparability(metrics, reference_ops)
  sc      = score(metrics)
  dc      = repo == OUR_REPO ? nil : compare_decisions(local_decisions, decisions)

  puts "  ops=#{metrics[:total_operations].inspect} dist=#{metrics[:dist_source].inspect} " \
       "count_tvd=#{metrics[:count_tvd_pp].inspect} vol_tvd=#{metrics[:volume_tvd_pp].inspect} " \
       "success=#{metrics[:success_rate_pct].inspect} score=#{sc ? sc[:value] : '—'}"
  puts "  ⚠ вне рейтинга: #{comp[:reasons].join('; ')}" unless comp[:comparable]
  puts "  ⚠ #{metrics[:warnings].join('; ')}" unless metrics[:warnings].empty?
  puts "  decisions match: #{dc ? "#{dc[:match_rate_pct]}% (#{dc[:common_operations]} общих)" : 'нет данных'}" if repo != OUR_REPO

  results << { repo: repo, metrics: metrics, score: sc, comparability: comp, decisions_vs_ours: dc }
end

competitors.each do |full_name|
  owner, repo = full_name.split('/', 2)
  puts "\nОбрабатываем #{full_name}..."
  sleep 0.5

  begin
    report = fetch_json_file(owner, repo, 'routing_report_test.json')
    decisions = fetch_json_file(owner, repo, 'routing_decisions_test.json')
    if report.nil? && decisions.nil?
      puts '  нет ни отчёта, ни решений — пропуск'
      next
    end
    process.call(full_name, 'github', report, decisions)
  rescue StandardError => e
    warn "  ✗ Ошибка обработки #{full_name}: #{e.class}: #{e.message}"
  end
end

unless FLAGS[:no_network]
  KNOWN_GITLAB_REPOS.each do |ns|
    puts "\n[GitLab] Обрабатываем #{ns}..."
    begin
      report = fetch_gitlab_json_file(ns, 'routing_report_test.json')
      decisions = fetch_gitlab_json_file(ns, 'routing_decisions_test.json')
      if report.nil? && decisions.nil?
        puts '  нет ни отчёта, ни решений — пропуск'
        next
      end
      process.call("gitlab:#{ns}", 'gitlab', report, decisions)
    rescue StandardError => e
      warn "  ✗ Ошибка обработки GitLab #{ns}: #{e.class}: #{e.message}"
    end
  end
end

puts "\nОбрабатываем себя..."
process.call(OUR_REPO, 'local', local_report, local_decisions)

# Ранг только среди сопоставимых и посчитанных.
rankable, unranked = results.partition { |r| r[:comparability][:comparable] && r[:score] }

# Строгий скор: только те компоненты, что есть у ВСЕХ ранжируемых репо.
# Иначе команда без volume-отчёта получает преимущество просто за отсутствие данных.
common_components = WEIGHTS.keys.select do |k|
  rankable.any? && rankable.all? { |r| !score_components(r[:metrics])[k].nil? }
end
rankable.each { |r| r[:score_strict] = score(r[:metrics], only: common_components) }

ranked = rankable
         .sort_by { |r| [r[:score_strict] ? r[:score_strict][:value] : 1e9,
                         r[:score][:value], r[:metrics][:count_tvd_pp] || 1e9] }
         .each_with_index
         .map { |r, i| { rank: i + 1, repo: r[:repo], score: r[:score],
                         score_strict: r[:score_strict], metrics: r[:metrics] } }

generated_at = Time.now.utc

comparison = {
  generated_at: generated_at.iso8601,
  our_repo: OUR_REPO,
  reference_operations: reference_ops,
  methodology: {
    weights: WEIGHTS,
    strict_components: common_components,
    strict_note: 'основной ранг — по score_strict: компоненты, доступные у всех ранжируемых репо; ' \
                 'score (полный) — справочно, между partial-строками несопоставим',
    deviation_metric: 'TVD_pp = 0.5 * sum(|share - target|) по всем провайдерам, включая цель 0',
    deviation_base: 'target (паспортная цель); дополнительно приводится max dev от achievable',
    count_share_source: 'routing_decisions_test.json при точном совпадении operation_id, иначе отчёт',
    sample_tolerance_pct: SAMPLE_TOLERANCE_PCT,
    format_gate: "известных провайдеров >= #{MIN_KNOWN_PROVIDERS}, сумма долей 100 +- #{SHARES_SUM_TOLERANCE_PCT} п.п."
  },
  excluded_repos: EXCLUDED_REPOS,
  total_processed: results.size,
  ranked_count: ranked.size,
  rankings: ranked,
  unranked: unranked.map { |r| { repo: r[:repo], reasons: r[:comparability][:reasons], metrics: r[:metrics] } },
  details: results
}

json_path = File.join(OUTPUT_DIR, 'competitor_comparison.json')
File.write(json_path, JSON.pretty_generate(comparison))
puts "\nJSON: #{json_path}"

unless FLAGS[:json_only]
  md_path = File.join(OUTPUT_DIR, 'competitor_comparison.md')
  File.write(md_path, render_markdown(results, ranked, unranked, generated_at, reference_ops, common_components))
  puts "Markdown: #{md_path}"
end

puts "\n=== Рейтинг (score* — строгий, по общим компонентам #{common_components.join(', ')}; меньше = лучше) ==="
ranked.each do |r|
  m = r[:metrics]
  mark = r[:repo] == OUR_REPO ? ' ← МЫ' : ''
  part = r[:score][:partial] ? " [partial: нет #{r[:score][:missing].join(',')}]" : ''
  st = r[:score_strict]
  puts "  #{r[:rank]}. #{r[:repo]}#{mark}  score*=#{st ? st[:value] : '—'}  (полный=#{r[:score][:value]}#{part})"
  puts "     count_tvd=#{fmt m[:count_tvd_pp]}pp  vol_tvd=#{fmt m[:volume_tvd_pp]}pp  " \
       "maxdev/target=#{fmt m[:count_max_dev_pp]}pp  maxdev/ach=#{fmt m[:count_max_dev_vs_achievable_pp]}pp  " \
       "success=#{fmt m[:success_rate_pct]}%  fallback=#{fmt m[:fallback_rate_pct]}%  ops=#{fmt m[:total_operations]}"
end

unless unranked.empty?
  puts "\n=== Вне рейтинга (несопоставимые) ==="
  unranked.each { |r| puts "  - #{r[:repo]}: #{r[:comparability][:reasons].join('; ')}" }
end
