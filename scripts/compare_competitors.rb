#!/usr/bin/env ruby
# frozen_string_literal: true

# Автоматическое сравнение routing_report_test.json и routing_decisions_test.json
# со всеми публичными репозиториями на GitHub, содержащими эти файлы.
#
# Использование:
#   GITHUB_TOKEN=<token> ruby scripts/compare_competitors.rb
#   ruby scripts/compare_competitors.rb              # токен берётся из `gh auth token`
#   ruby scripts/compare_competitors.rb --json-only  # только JSON без Markdown

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

ROOT        = File.expand_path('..', __dir__)
LOCAL_REPORT    = File.join(ROOT, 'routing_report_test.json')
LOCAL_DECISIONS = File.join(ROOT, 'routing_decisions_test.json')
OUTPUT_DIR  = File.join(ROOT, 'out', 'competitor_analysis')

GITHUB_TOKEN = (ENV['GITHUB_TOKEN'] || `gh auth token 2>/dev/null`.strip).freeze

# Провайдеры для которых паспортные цели заданы (spacepayments — аварийный fallback)
PRIMARY_PROVIDERS = %w[vipay payflow quickpay].freeze

# Минимальное число операций для «репрезентативного» результата
SMALL_QUEUE_THRESHOLD = 20

# --------------------------------------------------------------------------- #
# GitHub API
# --------------------------------------------------------------------------- #

def github_headers
  h = {
    'Accept'     => 'application/vnd.github.v3+json',
    'User-Agent' => 'smart-router-42-compare/1.0'
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
rescue => e
  warn "  HTTP error: #{e.message}"
  nil
end

# Поиск репозиториев по одному запросу, возвращает массив full_name.
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
rescue => e
  warn "  Ошибка поиска '#{query}': #{e.message}"
  []
end

# Расширенный поиск через несколько запросов, результаты объединяются.
def search_all_repos
  queries = [
    'filename:routing_report_test.json',
    'filename:routing_decisions_test.json',
    # по содержимому — ищем специфичные поля из формата хакатона
    '"routing_report_test" extension:json',
    '"selected_provider" "operation_id" filename:routing_decisions_test.json',
    '"deviation_pp" "target_pct" extension:json',
    '"vipay" "payflow" "quickpay" filename:routing_report_test.json',
    '"spacepayments" "count_share" extension:json',
  ]

  found = []
  queries.each do |q|
    print "  Запрос: #{q[0..60]}... "
    before = found.size
    found += search_one(q)
    found = found.uniq
    puts "+#{found.size - before} (итого #{found.size})"
    sleep 1.0
  end
  found.uniq
end

# Загружает и декодирует JSON-файл из репозитория через Contents API.
def fetch_json_file(owner, repo, path)
  data = github_get("https://api.github.com/repos/#{owner}/#{repo}/contents/#{path}")
  return nil unless data && data['content']
  JSON.parse(Base64.decode64(data['content']).force_encoding('UTF-8'))
rescue JSON::ParserError => e
  warn "  Некорректный JSON #{owner}/#{repo}/#{path}: #{e.message}"
  nil
rescue => e
  warn "  Не удалось получить #{owner}/#{repo}/#{path}: #{e.message}"
  nil
end

# --------------------------------------------------------------------------- #
# GitLab API
# --------------------------------------------------------------------------- #

GITLAB_TOKEN = ENV['GITLAB_TOKEN']

def gitlab_get(url)
  uri = URI(url)
  headers = { 'User-Agent' => 'smart-router-42-compare/1.0' }
  headers['PRIVATE-TOKEN'] = GITLAB_TOKEN if GITLAB_TOKEN
  Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 15) do |http|
    res = http.request(Net::HTTP::Get.new(uri, headers))
    return nil if res.code == '404'
    raise "GitLab API #{res.code}" unless res.code == '200'
    JSON.parse(res.body)
  end
rescue => e
  warn "  GitLab HTTP error: #{e.message}"
  nil
end

def fetch_gitlab_json_file(namespace_path, path, ref: 'main')
  encoded_path = URI.encode_www_form_component(path)
  encoded_ns   = URI.encode_www_form_component(namespace_path)
  url = "https://gitlab.com/api/v4/projects/#{encoded_ns}/repository/files/#{encoded_path}/raw?ref=#{ref}"
  uri = URI(url)
  headers = { 'User-Agent' => 'smart-router-42-compare/1.0' }
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
rescue => e
  warn "  Не удалось получить GitLab #{namespace_path}/#{path}: #{e.message}"
  nil
end

def process_gitlab_repo(namespace_path)
  report    = fetch_gitlab_json_file(namespace_path, 'routing_report_test.json')
  return nil unless report
  decisions = fetch_gitlab_json_file(namespace_path, 'routing_decisions_test.json')
  [report, decisions]
end

# --------------------------------------------------------------------------- #
# Извлечение метрик (нормализует разные форматы разных команд)
# --------------------------------------------------------------------------- #

def dig_first(hash, *paths)
  paths.each do |path|
    v = path.reduce(hash) { |h, k| h.is_a?(Hash) ? h[k] : nil }
    return v unless v.nil?
  end
  nil
end

def extract_metrics(report)
  return nil unless report.is_a?(Hash)

  dist     = report['distribution']     || {}
  vol_dist = report['volume_distribution'] || {}
  outcomes = report['outcomes_summary'] || report['outcomes'] || report['simulated_results'] || {}
  fallback = report['fallback']         || report['fallback_usage'] || {}
  cost     = report['cost_efficiency']  || {}
  bm       = report['benchmark']        || {}
  qc       = report['queue_coverage']   || report['routing_coverage'] || {}
  kpis     = report['routing_kpis']     || {}

  # Approved / rejected / expired — могут быть числом или хэшем {count:, share_pct:}
  unpack = ->(v) { v.is_a?(Hash) ? v['count'] : v }
  approved = unpack.(outcomes['approved'])
  rejected = unpack.(outcomes['rejected'])
  expired  = unpack.(outcomes['expired'])

  success_rate = outcomes['success_rate_pct'] || outcomes['approval_rate_pct']

  fallback_ops = dig_first(
    report,
    ['fallback', 'recovered_by_fallback'],
    ['fallback', 'count'],
    ['fallback_count'],
    ['routing_kpis', 'fallback_operations'],
    ['routing_resilience', 'fallback_count']
  ) || 0

  fallback_rate = dig_first(
    report,
    ['fallback', 'fallback_rate_pct'],
    ['fallback_usage', 'share_pct'],
    ['routing_resilience', 'fallback_share_pct'],
    ['fallback', 'share_pct']
  ) || 0

  retry_count = report['retry_count'] ||
                kpis['cascade_operations'] ||
                dig_first(report, ['routing_resilience', 'operations_retried']) || 0

  queue_ops = qc['queue_operations'] || report['total_operations'] || 0
  coverage  = qc['coverage_pct']     || qc['decision_coverage_pct'] || 100.0

  # target_deviations — отдельный блок верхнего уровня (формат denis-gordeev и аналогичных)
  top_devs = report['target_deviations'] || {}

  # Отклонение ВСЕГДА считаем от target (share_pct - target_pct) для честного сравнения.
  # Некоторые команды хранят deviation от achievable — это разные метрики.
  pick_dev = ->(provider, v) {
    s = v['share_pct']
    t = v['target_pct']
    (s && t) ? (s.to_f - t.to_f).round(2) : nil
  }

  # Отклонение от цели для основных провайдеров (от target, единая база)
  count_devs = PRIMARY_PROVIDERS.filter_map do |p|
    v = dist[p]
    next unless v
    pick_dev.(p, v)&.abs
  end
  max_count_dev = count_devs.max || 0

  # success_rate — перебираем все известные форматы
  success_rate ||= report['success_rate_pct']
  # results.approval_rate_pct (camtimhamilton и др.)
  if success_rate.nil? && report['results'].is_a?(Hash) && !report['results'].values.all? { |v| v.is_a?(Hash) }
    success_rate = report.dig('results', 'approval_rate_pct')
  end
  # outcomes.end_to_end_success_rate (stasvinokur: 90 доставлено через fallback)
  success_rate ||= outcomes['end_to_end_success_rate']&.*(100)
  # status_summary.approved (TomYamTUSUR)
  if success_rate.nil? && report['status_summary']
    ss = report['status_summary']
    approved_cnt = ss.dig('approved', 'count') || ss['approved']
    total = report['total_operations']
    success_rate = (approved_cnt.to_f / total * 100).round(1) if approved_cnt && total&.positive?
  end
  # Вычисляем из approved/total если есть счётчики
  if success_rate.nil?
    total = report['total_operations']
    approved_cnt = unpack.(outcomes['approved']) ||
                   report.dig('results', 'approved') ||
                   report.dig('routing_quality', 'approved')
    # W0lfhack: суммируем approved по провайдерам из results
    if approved_cnt.nil? && report['results'].is_a?(Hash)
      approved_cnt = report['results'].values.sum { |v| v.is_a?(Hash) ? (v['approved'] || 0) : 0 }
      approved_cnt = nil if approved_cnt.zero?
    end
    success_rate = (approved_cnt.to_f / total * 100).round(1) if approved_cnt && total&.positive?
  end

  # fallback из routing_quality (формат korowood и аналогичных)
  rq = report['routing_quality'] || {}
  fallback_ops = fallback_ops.zero? ? (rq['fallback_count'] || 0) : fallback_ops
  # outcomes.fallback_triggered (stasvinokur)
  fallback_ops = outcomes['fallback_triggered'] || fallback_ops if fallback_ops.zero?
  # retry/resilience
  retry_count = retry_count.zero? ? (outcomes['fallback_triggered'] || 0) : retry_count

  {
    total_operations: report['total_operations'],
    queue_ops_in_scope: queue_ops.to_i,
    strategy: report['strategy'] || report['strategy_profile'] || report.dig('policy', 'name'),
    max_count_deviation_pp: max_count_dev.round(2),
    distribution: dist.map { |p, v|
      [p, {
        count:       v['count'],
        share_pct:   v['share_pct'],
        target_pct:  v['target_pct'],
        deviation_pp: pick_dev.(p, v)&.round(2)
      }]
    }.to_h,
    volume_distribution: vol_dist.map { |p, v|
      vol_dev = v['deviation_pp'] || v['delta_pct'] || v['deviation_pct'] ||
                v['deviation_pct_points'] ||
                top_devs.dig(p, 'amount_share_delta_pct') ||
                ((v['share_pct'] && v['target_pct']) ? (v['share_pct'] - v['target_pct']).round(2) : nil)
      [p, { share_pct: v['share_pct'], target_pct: v['target_pct'], deviation_pp: vol_dev&.round(2) }]
    }.to_h,
    approved: approved,
    rejected: rejected,
    expired:  expired,
    success_rate_pct:  success_rate,
    fallback_ops:      fallback_ops,
    fallback_rate_pct: fallback_rate.round(2),
    retry_count:       retry_count,
    queue_coverage_pct: coverage,
    cost_efficiency_vs_best_pct: cost['vs_best_pct'],
    margin_earned:               cost['margin_earned'],
    benchmark_competitive_ratio: bm['competitive_ratio'],
    benchmark_max_deviation_pp:  bm.dig('our_online_result', 'max_deviation_pp')
  }
end

# --------------------------------------------------------------------------- #
# Сравнение routing_decisions_test (пооперационно)
# --------------------------------------------------------------------------- #

def compare_decisions(local_arr, competitor_arr)
  return nil unless local_arr.is_a?(Array) && competitor_arr.is_a?(Array)

  local_map = local_arr.each_with_object({}) { |d, h| h[d['operation_id']] = d['selected_provider'] }
  comp_map  = competitor_arr.each_with_object({}) { |d, h| h[d['operation_id']] = d['selected_provider'] }
  common    = local_map.keys & comp_map.keys
  return nil if common.empty?

  matches   = common.count { |op| local_map[op] == comp_map[op] }
  mismatches = common.reject { |op| local_map[op] == comp_map[op] }.map do |op|
    { operation_id: op, ours: local_map[op], theirs: comp_map[op] }
  end

  {
    common_operations:  common.size,
    matching_decisions: matches,
    match_rate_pct:     (matches.to_f / common.size * 100).round(1),
    provider_frequency: comp_map.values.tally.sort_by { |_, c| -c }.to_h,
    mismatches_sample:  mismatches.first(10)
  }
end

# --------------------------------------------------------------------------- #
# Форматирование вывода
# --------------------------------------------------------------------------- #

def render_markdown(our_repo, results, ranked, generated_at)
  lines = []
  lines << "# Сравнение конкурентов — routing_report_test"
  lines << ""
  lines << "_Сгенерировано: #{generated_at.strftime('%Y-%m-%d %H:%M UTC')}_"
  lines << ""
  lines << "## Рейтинг по максимальному отклонению count-share от цели (меньше = лучше)"
  lines << ""
  lines << "| # | Репозиторий | Queue ops | Max dev (pp) | Success% | Fallback ops | Fallback% | Retries | vs_best% | comp_ratio |"
  lines << "|---|-------------|-----------|-------------|---------|-------------|-----------|---------|---------|-----------|"

  ranked.each do |r|
    m     = r[:metrics]
    small = m[:queue_ops_in_scope] < SMALL_QUEUE_THRESHOLD
    label = r[:repo]
    label += ' ← **МЫ**'      if r[:repo] == our_repo
    label += ' ⚠ малая выборка' if small
    lines << "| #{r[:rank]} | #{label} | " \
             "#{m[:queue_ops_in_scope]} | #{m[:max_count_deviation_pp]&.round(1)} | " \
             "#{m[:success_rate_pct]} | #{m[:fallback_ops]} | #{m[:fallback_rate_pct]} | " \
             "#{m[:retry_count]} | #{m[:cost_efficiency_vs_best_pct]} | #{m[:benchmark_competitive_ratio]} |"
  end

  lines << ""
  lines << "## Детали по каждому репозиторию"

  results.each do |entry|
    m  = entry[:metrics]
    dc = entry[:decisions_vs_ours]
    lines << ""
    lines << "### #{entry[:repo]}#{entry[:repo] == our_repo ? ' ← МЫ' : ''}"
    lines << ""
    lines << "- **Операций в отчёте**: #{m[:total_operations]} (в тестовой очереди: #{m[:queue_ops_in_scope]})"
    lines << "- **Стратегия**: `#{m[:strategy]}`"
    lines << "- **Coverage**: #{m[:queue_coverage_pct]}%"
    lines << "- **Результаты**: #{m[:approved]} approved / #{m[:rejected]} rejected / #{m[:expired]} expired" \
             " (success #{m[:success_rate_pct]}%)"
    lines << "- **Fallback**: #{m[:fallback_ops]} ops (#{m[:fallback_rate_pct]}%)"
    lines << "- **Retries / каскады**: #{m[:retry_count]}"
    lines << "- **Margin vs best**: #{m[:cost_efficiency_vs_best_pct]}%" if m[:cost_efficiency_vs_best_pct]
    lines << "- **Benchmark competitive ratio**: #{m[:benchmark_competitive_ratio]}" if m[:benchmark_competitive_ratio]
    lines << ""
    lines << "**Count-share distribution:**"
    lines << ""
    lines << "| Provider | Count | Share% | Target% | Dev (pp) |"
    lines << "|----------|-------|--------|---------|---------|"
    (m[:distribution] || {}).each do |prov, v|
      lines << "| #{prov} | #{v[:count]} | #{v[:share_pct]} | #{v[:target_pct]} | #{v[:deviation_pp]} |"
    end

    if m[:volume_distribution] && !m[:volume_distribution].empty?
      lines << ""
      lines << "**Volume-share distribution:**"
      lines << ""
      lines << "| Provider | Share% | Target% | Dev (pp) |"
      lines << "|----------|--------|---------|---------|"
      m[:volume_distribution].each do |prov, v|
        lines << "| #{prov} | #{v[:share_pct]} | #{v[:target_pct]} | #{v[:deviation_pp]} |"
      end
    end

    if dc
      lines << ""
      lines << "**Сравнение routing_decisions_test с нашим:**"
      lines << "- Общих операций: #{dc[:common_operations]}"
      lines << "- Совпали решения: #{dc[:matching_decisions]} (#{dc[:match_rate_pct]}%)"
      lines << "- Частота провайдеров: #{dc[:provider_frequency].map { |k, v| "#{k}=#{v}" }.join(', ')}"
      unless dc[:mismatches_sample].empty?
        lines << "- Примеры расхождений (первые #{dc[:mismatches_sample].size}):"
        dc[:mismatches_sample].each do |mm|
          lines << "  - `#{mm[:operation_id]}`: они → **#{mm[:theirs]}**, мы → #{mm[:ours]}"
        end
      end
    end
  end

  lines << ""
  lines << "---"
  lines << "_Excluded: #{EXCLUDED_REPOS.join(', ')}_"
  lines.join("\n")
end

# --------------------------------------------------------------------------- #
# MAIN
# --------------------------------------------------------------------------- #

json_only = ARGV.include?('--json-only')
FileUtils.mkdir_p(OUTPUT_DIR)

puts "=== Сравнение конкурентов ==="
puts "Ищем репозитории на GitHub (расширенный поиск)..."
found = search_all_repos
puts "Найдено уникальных репо через поиск: #{found.size}"

all_repos = (found + KNOWN_REPOS).uniq
puts "После добавления ручных ссылок: #{all_repos.size}"

competitors = all_repos.reject { |r| EXCLUDED_REPOS.include?(r) }
puts "После исключений: #{competitors.size}"
competitors.each { |r| puts "  - #{r}" }

# Грузим свои файлы
local_report    = JSON.parse(File.read(LOCAL_REPORT))
local_decisions = JSON.parse(File.read(LOCAL_DECISIONS))
our_repo        = 'OUR/smart-router-42'

results = []

competitors.each do |full_name|
  owner, repo = full_name.split('/', 2)
  puts "\nОбрабатываем #{full_name}..."
  sleep 0.5

  report    = fetch_json_file(owner, repo, 'routing_report_test.json')
  next unless report

  decisions = fetch_json_file(owner, repo, 'routing_decisions_test.json')
  metrics   = extract_metrics(report)
  dc        = compare_decisions(local_decisions, decisions)

  small = metrics[:queue_ops_in_scope] < SMALL_QUEUE_THRESHOLD
  puts "  total_ops=#{metrics[:total_operations]} (в очереди: #{metrics[:queue_ops_in_scope]})#{small ? ' ⚠ малая выборка' : ''}, " \
       "max_dev=#{metrics[:max_count_deviation_pp]}pp, " \
       "success=#{metrics[:success_rate_pct]}%, " \
       "fallback=#{metrics[:fallback_rate_pct]}%"
  puts "  decisions match: #{dc ? "#{dc[:match_rate_pct]}% (#{dc[:common_operations]} общих)" : 'нет данных'}"

  results << { repo: full_name, metrics: metrics, decisions_vs_ours: dc }
end

# GitLab репозитории
KNOWN_GITLAB_REPOS.each do |ns|
  puts "\n[GitLab] Обрабатываем #{ns}..."
  pair = process_gitlab_repo(ns)
  next unless pair

  report, decisions = pair
  metrics = extract_metrics(report)
  dc      = compare_decisions(local_decisions, decisions)
  small   = metrics[:queue_ops_in_scope] < SMALL_QUEUE_THRESHOLD

  puts "  total_ops=#{metrics[:total_operations]} (в очереди: #{metrics[:queue_ops_in_scope]})#{small ? ' ⚠ малая выборка' : ''}, " \
       "max_dev=#{metrics[:max_count_deviation_pp]}pp, " \
       "success=#{metrics[:success_rate_pct]}%, " \
       "fallback=#{metrics[:fallback_rate_pct]}%"
  puts "  decisions match: #{dc ? "#{dc[:match_rate_pct]}% (#{dc[:common_operations]} общих)" : 'нет данных'}"

  results << { repo: "gitlab:#{ns}", metrics: metrics, decisions_vs_ours: dc }
end

# Добавляем себя
our_metrics = extract_metrics(local_report)
results << { repo: our_repo, metrics: our_metrics, decisions_vs_ours: nil }

# Ранжируем по max_count_deviation_pp (меньше = лучше)
ranked = results
  .map { |r| { repo: r[:repo], metrics: r[:metrics] } }
  .sort_by { |r| r[:metrics][:max_count_deviation_pp] || 999 }
  .each_with_index
  .map { |r, i| r.merge(rank: i + 1) }

generated_at = Time.now.utc

# JSON-вывод
comparison = {
  generated_at: generated_at.iso8601,
  our_repo: our_repo,
  excluded_repos: EXCLUDED_REPOS,
  total_compared: results.size,
  rankings: ranked,
  details: results
}

json_path = File.join(OUTPUT_DIR, 'competitor_comparison.json')
File.write(json_path, JSON.pretty_generate(comparison))
puts "\nJSON: #{json_path}"

# Markdown-вывод
unless json_only
  md_path = File.join(OUTPUT_DIR, 'competitor_comparison.md')
  File.write(md_path, render_markdown(our_repo, results, ranked, generated_at))
  puts "Markdown: #{md_path}"
end

# Итог в консоль
puts "\n=== Рейтинг (по max count-share deviation, меньше = лучше) ==="
ranked.each do |r|
  m     = r[:metrics]
  mark  = r[:repo] == our_repo ? ' ← МЫ' : ''
  small = m[:queue_ops_in_scope] < SMALL_QUEUE_THRESHOLD ? ' [⚠ малая выборка]' : ''
  puts "  #{r[:rank]}. #{r[:repo]}#{mark}#{small}"
  puts "     queue_ops=#{m[:queue_ops_in_scope]}  max_dev=#{m[:max_count_deviation_pp]}pp  success=#{m[:success_rate_pct]}%  fallback=#{m[:fallback_rate_pct]}%  retries=#{m[:retry_count]}"
end
