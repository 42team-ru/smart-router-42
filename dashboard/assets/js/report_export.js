/* Экспорт /report в самостоятельный HTML-файл.
 *
 * Один файл, никаких внешних ресурсов: стили и разметка вшиты целиком, чтобы
 * открывался локально (file://) и годился для пересылки — без бэкенда и без
 * сети. Источник данных — уже загруженные srv.report/srv.overview, свежих
 * запросов модуль не делает.
 */
(function (global) {
  'use strict';

  var F = global.RCFormat;
  var esc = F.esc;

  function pct1(v) { return (v === null || v === undefined) ? '—' : v.toFixed(1) + '%'; }
  function signed(v) { return (v === null || v === undefined) ? '—' : (v > 0 ? '+' : '') + v.toFixed(1); }

  function filterLabel(filters) {
    var parts = [];
    if (filters.since) parts.push('since ' + filters.since);
    if (filters.until) parts.push('until ' + filters.until);
    if (filters.merchant) parts.push('merchant ' + filters.merchant);
    if (filters.gate) parts.push('gate ' + filters.gate);
    if (filters.provider) parts.push('provider ' + filters.provider);
    return parts.length ? parts.join(' · ') : 'без фильтров — вся выборка';
  }

  function tile(label, value, sub, color) {
    return '<div class="tile">' +
      '<div class="tl">' + esc(label) + '</div>' +
      '<div class="tv" style="color:' + (color || '#181818') + '">' + esc(value) + '</div>' +
      (sub ? '<div class="ts">' + esc(sub) + '</div>' : '') +
    '</div>';
  }

  function providerRows(report, colorFor) {
    var names = Object.keys(report.distribution || {});
    return names.map(function (name) {
      var d = (report.distribution || {})[name] || {};
      var v = (report.volume_distribution || {})[name] || {};
      var a = (report.attempt_distribution || {})[name] || {};
      var u = (report.projected_daily_utilization || {})[name] || {};
      var conv = a.observed_conversion;
      var convColor = conv === null || conv === undefined ? '#8a8a8a'
        : conv > 0.85 ? '#007a4d' : conv > 0.7 ? '#b45900' : '#d31510';
      var devColor = Math.abs(d.deviation_pp || 0) > 5 ? '#b45900' : '#505050';

      return '<tr>' +
        '<td><span class="sw" style="background:' + colorFor(name) + '"></span>' + esc(name) + '</td>' +
        '<td class="r mono">' + F.fi(d.count || 0) + '</td>' +
        '<td class="r mono">' + pct1(d.share_pct) + ' / ' + (d.target_pct === undefined ? '—' : d.target_pct + '%') + '</td>' +
        '<td class="r mono" style="color:' + devColor + '">' + signed(d.deviation_pp) + ' п.п.</td>' +
        '<td class="r mono">' + F.fmk(v.amount || 0) + '</td>' +
        '<td class="r mono">' + (a.attempts || 0) + '</td>' +
        '<td class="r mono" style="color:' + convColor + '">' + (conv === null || conv === undefined ? '—' : (conv * 100).toFixed(1) + '%') + '</td>' +
        '<td class="r mono">' + (u.utilization_pct === null || u.utilization_pct === undefined ? '—' : u.utilization_pct.toFixed(1) + '%') + '</td>' +
      '</tr>';
    }).join('');
  }

  function listCard(title, note, items, emptyText) {
    var body = items.length
      ? '<ul class="plain">' + items.map(function (x) { return '<li>' + esc(x) + '</li>'; }).join('') + '</ul>'
      : '<div class="empty">' + esc(emptyText) + '</div>';
    return '<div class="card">' +
      '<div class="card-h"><span>' + esc(title) + '</span>' + (note ? '<span class="note">' + esc(note) + '</span>' : '') + '</div>' +
      body +
    '</div>';
  }

  function skipReasonsCard(report) {
    var skips = report.skip_reasons || {};
    var keys = Object.keys(skips).sort(function (a, b) { return skips[b] - skips[a]; });
    var body = keys.length
      ? '<table class="kv"><tbody>' + keys.map(function (k) {
          return '<tr><td>' + esc(k) + '</td><td class="r mono">' + F.fi(skips[k]) + '</td></tr>';
        }).join('') + '</tbody></table>'
      : '<div class="empty">Отсева в выборке нет.</div>';
    return '<div class="card"><div class="card-h"><span>Причины отсева</span></div>' + body + '</div>';
  }

  function fallbackCard(report) {
    var fb = report.fallback || {};
    var rows = [
      ['Успех с первой попытки', F.fi(fb.first_attempt_success || 0)],
      ['Восстановлено каскадом', F.fi(fb.recovered_by_fallback || 0)],
      ['Fallback rate', pct1(fb.fallback_rate_pct)],
      ['Каскад исчерпан', F.fi(fb.cascade_exhausted || 0)],
      ['Ушло на spacepayments', F.fi(fb.spacepayments_used || 0)]
    ];
    return '<div class="card"><div class="card-h"><span>Каскад и фоллбэк</span></div>' +
      '<table class="kv"><tbody>' + rows.map(function (r) {
        return '<tr><td>' + esc(r[0]) + '</td><td class="r mono">' + r[1] + '</td></tr>';
      }).join('') + '</tbody></table></div>';
  }

  function build(ctx) {
    var report = ctx.report || {};
    var overview = ctx.overview || { total: 0, outcomes: {}, avg_latency_sec: null };
    var colors = ctx.colors || {};
    var colorFor = function (name) { return colors[name] || '#0265dc'; };

    var apRate = overview.total ? (overview.approved_count / overview.total * 100) : null;
    var badOutcomes = (overview.outcomes.rejected || 0) + (overview.outcomes.expired || 0) + (overview.outcomes.no_provider || 0);

    var tiles = [
      tile('Операций в выборке', F.fi(report.total_operations || 0), 'период ' + (report.period || '—')),
      tile('Approve rate', apRate === null ? '—' : apRate.toFixed(1) + '%', 'по simulated_result', '#007a4d'),
      tile('Одобренный объём', F.fmk(overview.approved_amount || 0)),
      tile('Неуспешных исходов', F.fi(badOutcomes), null, badOutcomes ? '#d31510' : '#181818'),
      tile('Средний latency', overview.avg_latency_sec === null ? '—' : overview.avg_latency_sec + ' сек')
    ].join('');

    var rows = providerRows(report, colorFor);
    var providersTable = '<div class="card">' +
      '<div class="card-h"><span>Разрез по провайдерам</span><span class="note">distribution / volume_distribution / attempt_distribution</span></div>' +
      '<table class="data">' +
        '<thead><tr>' +
          '<th>Провайдер</th><th class="r">Решений</th><th class="r">Доля / цель</th><th class="r">Откл.</th>' +
          '<th class="r">Объём</th><th class="r">Попыток</th><th class="r">Конверсия</th><th class="r">Дневной лимит</th>' +
        '</tr></thead>' +
        '<tbody>' + (rows || '<tr><td colspan="8" class="empty">Выборка пуста.</td></tr>') + '</tbody>' +
      '</table></div>';

    var sections = [
      fallbackCard(report),
      skipReasonsCard(report),
      listCard('Причины отклонений', 'deviation_causes', report.deviation_causes || [], 'Отклонений ≥ 5 п.п. от цели не найдено.'),
      listCard('Рекомендации движка', 'recommendations', report.recommendations || [], 'Рекомендаций нет — метрики в допуске.')
    ].join('');

    var meta = ctx.meta || {};
    var genAt = new Date(ctx.generatedAt || Date.now());
    var genLabel = genAt.toLocaleString('ru-RU');

    return '<!doctype html><html lang="ru"><head><meta charset="utf-8">' +
      '<meta name="viewport" content="width=device-width, initial-scale=1">' +
      '<title>Отчёт маршрутизации · ' + esc(genLabel) + '</title>' +
      '<style>' + styles() + '</style></head><body>' +
      '<div class="wrap">' +
        '<header class="head">' +
          '<div class="brand"><span class="logo"></span><span>Routing Console</span></div>' +
          '<h1>Отчёт маршрутизации</h1>' +
          '<div class="sub">Сформирован ' + esc(genLabel) + ' · стратегия <b class="mono">' + esc(report.strategy || meta.strategy || '—') + '</b></div>' +
          '<div class="chips">' +
            '<span class="chip">' + esc(filterLabel(ctx.filters || {})) + '</span>' +
            (meta.gate ? '<span class="chip">gate ' + esc(meta.gate) + '</span>' : '') +
            (meta.merchant ? '<span class="chip">merchant ' + esc(meta.merchant) + '</span>' : '') +
          '</div>' +
        '</header>' +
        '<div class="tiles">' + tiles + '</div>' +
        providersTable +
        sections +
        '<footer>Сгенерировано локально из GET /report и GET /analytics/overview панелью Routing Console. Файл ничего не отправляет и не подгружает по сети.</footer>' +
      '</div>' +
    '</body></html>';
  }

  function styles() {
    return '' +
      '*{box-sizing:border-box}' +
      'body{margin:0;background:#f5f5f5;color:#181818;font:14px/1.5 "Source Sans 3",system-ui,-apple-system,Segoe UI,sans-serif;-webkit-font-smoothing:antialiased}' +
      '.mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}' +
      '.wrap{max-width:920px;margin:0 auto;padding:32px 20px 60px}' +
      '.head{background:#181818;color:#fff;border-radius:14px;padding:26px 28px;margin-bottom:20px}' +
      '.brand{display:flex;align-items:center;gap:8px;font-weight:700;font-size:13px;letter-spacing:.02em;color:#b8c4d6;text-transform:uppercase;margin-bottom:14px}' +
      '.logo{width:9px;height:9px;border-radius:2px;background:#4d9bff;display:inline-block}' +
      '.head h1{margin:0 0 8px;font-size:26px}' +
      '.head .sub{color:#c7c7c7;font-size:13px}' +
      '.chips{display:flex;flex-wrap:wrap;gap:8px;margin-top:14px}' +
      '.chip{background:rgba(255,255,255,.1);border:1px solid rgba(255,255,255,.16);border-radius:20px;padding:5px 12px;font-size:12px;color:#e6e6e6}' +
      '.tiles{display:grid;grid-template-columns:repeat(5,1fr);gap:12px;margin-bottom:20px}' +
      '.tile{background:#fff;border:1px solid #e9e9e9;border-radius:10px;padding:14px}' +
      '.tl{font-size:11px;color:#747474;text-transform:uppercase;letter-spacing:.03em;margin-bottom:6px}' +
      '.tv{font-size:20px;font-weight:700;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}' +
      '.ts{font-size:11px;color:#959595;margin-top:4px}' +
      '.card{background:#fff;border:1px solid #e9e9e9;border-radius:10px;padding:16px 18px;margin-bottom:14px}' +
      '.card-h{display:flex;justify-content:space-between;align-items:baseline;margin-bottom:12px;font-weight:700;font-size:14px}' +
      '.card-h .note{font-weight:400;font-size:11px;color:#959595;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}' +
      'table.data{width:100%;border-collapse:collapse;font-size:13px}' +
      'table.data th{text-align:left;font-weight:600;font-size:11px;color:#747474;text-transform:uppercase;letter-spacing:.02em;padding:0 8px 8px;border-bottom:1px solid #e9e9e9}' +
      'table.data td{padding:8px;border-bottom:1px solid #f3f3f3;white-space:nowrap}' +
      'table.data .r,table.data th.r{text-align:right}' +
      'table.kv{width:100%;border-collapse:collapse;font-size:13px}' +
      'table.kv td{padding:6px 0;border-bottom:1px solid #f3f3f3}' +
      'table.kv .r{text-align:right;font-weight:600}' +
      '.sw{display:inline-block;width:8px;height:8px;border-radius:2px;margin-right:8px}' +
      'ul.plain{margin:0;padding-left:18px}' +
      'ul.plain li{margin-bottom:6px}' +
      '.empty{color:#959595;font-size:13px;padding:6px 0}' +
      'footer{text-align:center;color:#959595;font-size:11px;margin-top:24px}' +
      '@media (max-width:720px){.tiles{grid-template-columns:repeat(2,1fr)}}' +
      '@media print{body{background:#fff}.wrap{padding:0;max-width:none}.head{background:#181818;-webkit-print-color-adjust:exact;print-color-adjust:exact}}';
  }

  function download(html, filename) {
    var blob = new Blob([html], { type: 'text/html;charset=utf-8' });
    var url = URL.createObjectURL(blob);
    var a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
  }

  global.RCReportExport = { build: build, download: download };
})(window);
