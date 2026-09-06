/* Routing Console — состояние интерфейса и отрисовка.
 *
 * Данных своих не держит: всё, что видно на экране, приходит из RCApi
 * (assets/js/api.js) и пересобирается при каждой перезагрузке. Локально живут
 * только выбор страницы, тема, содержимое форм и черновик конфига.
 */
(function (global) {
  'use strict';

  var F = global.RCFormat;
  var Api = global.RCApi;
  var esc = F.esc;

  var THEME_KEY = 'rc-theme';
  var BUCKETS = 12;
  var COLORS = ['#0265dc', '#6f38b1', '#0d9488', '#cb5d00', '#0f766e', '#b45309', '#7c3aed', '#be123c'];
  var LIMITS = ['25', '50', '100', '500'];
  var NAV = [
    { id: 'overview', label: 'Обзор' },
    { id: 'sim', label: 'Симулятор' },
    { id: 'decisions', label: 'Аналитика' },
    { id: 'context', label: 'Контекст' }
  ];
  var OUTCOME_KEYS = ['approved', 'rejected', 'expired', 'no_provider'];

  var DEFAULT_BATCH = [
    { amount: 12000, bank: 'sberbank' },
    { amount: 480000, bank: 'tinkoff' },
    { amount: 3500, bank: 'alfa', card_brand: 'MIR' }
  ];

  // Ответы сервиса. Перетираются целиком на каждом reload().
  var srv = {
    health: null, caps: null, snapshot: null, config: null,
    state: null, report: null, overview: null, decisions: null,
    gate: null
  };

  var ui = {
    page: 'overview',
    theme: 'light',
    mode: 'single',
    amount: '15000',
    bank: '',
    brand: '',
    phone: '79001234567',
    bankName: 'Сбербанк',
    batchText: JSON.stringify(DEFAULT_BATCH, null, 2),
    runs: [],
    run: null,
    batchRes: null,
    filter: { since: '', until: '', merchant: '', gate: '', provider: '' },
    limit: 100,
    offset: 0,
    drawer: null,
    cfgDraft: null,
    seq: 0,
    booted: false
  };

  // ---------------------------------------------------------------- DOM utils

  function el(id) { return document.getElementById(id); }
  function setText(id, value) { var n = el(id); if (n) n.textContent = value; }
  function setHTML(id, html) { var n = el(id); if (n) n.innerHTML = html; }
  function show(id, visible) { var n = el(id); if (n) n.hidden = !visible; }

  function syncField(id, value) {
    var n = el(id);
    if (n && n.value !== value) n.value = value;
  }

  function fillOptions(id, options, selected) {
    var n = el(id);
    if (!n) return;
    n.innerHTML = options.map(function (o) {
      return '<option value="' + esc(o.v) + '">' + esc(o.l) + '</option>';
    }).join('');
    if (selected !== undefined) n.value = selected;
  }

  function index(list, key) {
    var out = {};
    (list || []).forEach(function (item) { out[item[key]] = item; });
    return out;
  }

  function pct(value) { return (value === null || value === undefined) ? '—' : value.toFixed(1) + '%'; }

  function hhmm(iso) {
    if (!iso) return '—';
    var d = new Date(iso);
    return String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0');
  }

  function hhmmss(iso) {
    if (!iso) return '—';
    var d = new Date(iso);
    return hhmm(iso) + ':' + String(d.getSeconds()).padStart(2, '0');
  }

  // datetime-local отдаёт время без зоны; сервис разбирает ISO 8601, поэтому
  // переводим в UTC явно, а не отправляем строку как есть.
  function toIso(local) {
    if (!local) return '';
    var d = new Date(local);
    return isNaN(d.getTime()) ? '' : d.toISOString();
  }

  function filterParams() {
    return {
      since: toIso(ui.filter.since),
      until: toIso(ui.filter.until),
      merchant: ui.filter.merchant,
      gate: ui.filter.gate,
      provider: ui.filter.provider
    };
  }

  function hasFilters() {
    return Object.keys(ui.filter).some(function (k) { return ui.filter[k]; });
  }

  // ------------------------------------------------------------------- toast

  var toastTimer = null;
  function flash(message, color) {
    if (toastTimer) clearTimeout(toastTimer);
    setText('toastText', message);
    el('toastDot').style.background = color || 'var(--pos)';
    show('toast', true);
    toastTimer = setTimeout(function () { show('toast', false); }, 4000);
  }

  function flashError(e) {
    var text = e && e.code ? e.code + ' · ' + e.message : String(e);
    if (e && e.details) {
      try { text += ' · ' + JSON.stringify(e.details); } catch (_) { /* циклов тут не бывает */ }
    }
    flash(text, 'var(--neg)');
  }

  // ------------------------------------------------------------------ загрузка

  function busy(on) {
    document.body.classList.toggle('is-busy', !!on);
  }

  function reload() {
    busy(true);
    return Api.health().then(function (health) {
      srv.health = health;
      if (!health.snapshot_loaded) {
        srv.gate = { title: 'Снапшот не загружен', kind: 'no_snapshot' };
        render();
        return null;
      }
      var filter = filterParams();
      return Promise.all([
        Api.capabilities(), Api.snapshot(), Api.config(), Api.state(),
        Api.report(filter), Api.overview(filter, BUCKETS),
        Api.decisions(filter, ui.limit, ui.offset)
      ]).then(function (r) {
        srv.caps = r[0]; srv.snapshot = r[1]; srv.config = r[2]; srv.state = r[3];
        srv.report = r[4]; srv.overview = r[5]; srv.decisions = r[6];
        srv.gate = null;
        if (ui.cfgDraft === null) ui.cfgDraft = draftFromConfig(srv.config);
        if (!ui.bank) ui.bank = defaultBank();
        ui.booted = true;
        render();
      });
    }).catch(function (e) {
      srv.gate = { title: 'Сервис недоступен', kind: 'transport', error: e };
      render();
    }).then(function () { busy(false); });
  }

  function defaultBank() {
    var banks = allBanks();
    return banks.length ? banks[0] : 'sberbank';
  }

  function allBanks() {
    var seen = {};
    (srv.snapshot ? srv.snapshot.providers : []).forEach(function (p) {
      if (p.exclude_banks) return;
      (p.banks || []).forEach(function (b) { seen[b] = true; });
    });
    return Object.keys(seen).sort();
  }

  // --------------------------------------------------------------- провайдеры

  // Паспорт из /snapshot и живые счётчики из /state — это два разных ответа
  // про один и тот же провайдер; сшиваем их по payment_system.
  function providers() {
    if (!srv.snapshot || !srv.state) return [];
    var counters = index(srv.state.providers, 'payment_system');
    var attempts = (srv.report && srv.report.attempt_distribution) || {};
    var buckets = (srv.overview && srv.overview.timeline.buckets) || [];

    return srv.snapshot.providers.map(function (p, i) {
      var name = p.payment_system;
      var st = counters[name] || {};
      var a = attempts[name] || {};
      var series = buckets.map(function (b) { return (b.attempts_by_provider || {})[name] || 0; });
      var used = st.daily_approved_amount || 0;
      var limit = p.daily_amount_limit;
      var shareFact = (st.share_bp || 0) / 100;
      var observed = (a.observed_conversion === undefined) ? null : a.observed_conversion;

      return {
        name: name,
        color: COLORS[i % COLORS.length],
        status: p.status,
        requisites: st.available_requisites === undefined ? p.available_requisites : st.available_requisites,
        shareFact: shareFact,
        target: p.traffic_percentage,
        drift: shareFact - p.traffic_percentage,
        inProgressCount: st.in_progress_count || 0,
        inProgressAmount: st.in_progress_amount || 0,
        dailyUsed: used,
        dailyLimit: limit,
        dailyPct: limit ? used / limit : null,
        series: series,
        tailAttempts: series.slice(-3).reduce(function (x, v) { return x + v; }, 0),
        attempts: a.attempts || 0,
        observed: observed,
        passportConversion: p.conversion_24h,
        latency: p.avg_latency_sec
      };
    });
  }

  // Одна лестница правил на две панели: подсветку строки провайдера и
  // сайдбар рисков. Порядок ветвлений и есть приоритет проблемы.
  function diagnose(p) {
    if (p.status !== 'active') {
      return { score: 92, why: 'status = ' + p.status + ' — вне выборки Planner', tone: 'neg',
               text: 'status = ' + p.status + ' — провайдер выключен в снапшоте, весь его трафик уходит в каскад' };
    }
    if (p.requisites === 0) {
      return { score: 96, why: '0 реквизитов — вне выборки Planner', tone: 'neg',
               text: 'available_requisites = 0 — Planner пропускает провайдера, его доля уходит в каскад и растит no_provider' };
    }
    if (p.inProgressCount > 0 && p.tailAttempts === 0) {
      return { score: 88, why: 'in_progress не двигается', tone: 'neg',
               text: 'залип: ' + p.inProgressCount + ' операций в in_progress, но в последних корзинах ни одной попытки' };
    }
    if (p.dailyPct !== null && p.dailyPct > 0.9) {
      return { score: 71, why: Math.round(p.dailyPct * 100) + '% дневного лимита', tone: 'warn',
               text: 'daily_approved_amount на ' + Math.round(p.dailyPct * 100) + '% лимита — крупные суммы отсекает limit_guard, доля уползёт вниз' };
    }
    if (Math.abs(p.drift) > 3) {
      return { score: 44, why: 'дрейф доли от цели', tone: 'warn',
               text: 'отклонение от traffic_percentage ' + (p.drift > 0 ? '+' : '') + p.drift.toFixed(1) + ' п.п. — проверьте стратегию и веса слоёв' };
    }
    return { score: 12, why: 'доля и лимиты в допуске', tone: 'pos', text: '' };
  }

  var TONE_COLOR = { neg: 'var(--neg)', warn: 'var(--warn)', pos: 'var(--pos)' };
  var TONE_BG = { neg: 'var(--negq)', warn: 'var(--warnq)', pos: 'var(--posq)' };

  // ------------------------------------------------------------- элементы UI

  function attemptStatus(a) {
    if (a.decision === 'skipped') return 'skipped';
    return a.result || 'selected';
  }

  function attemptTone(a) {
    return a.decision === 'skipped' ? F.tone('_none') : F.tone(a.result || 'approved');
  }

  function attemptRow(a, i, isLast) {
    var t = attemptTone(a);
    return '' +
      '<div class="att">' +
        '<div class="att-rail">' +
          '<div class="att-no" style="background:' + t.bg + ';color:' + t.fg + '">' + (i + 1) + '</div>' +
          '<div class="att-line" style="background:' + (isLast ? 'transparent' : 'var(--g300)') + '"></div>' +
        '</div>' +
        '<div class="att-body">' +
          '<div class="att-top">' +
            '<b>' + esc(a.provider) + '</b>' +
            '<span class="tag" style="background:' + t.bg + ';color:' + t.fg + '">' + esc(attemptStatus(a)) + '</span>' +
            '<span class="att-lat mono">' + esc(a.reason) + '</span>' +
          '</div>' +
          '<div class="att-reason">' + esc(a.details) + '</div>' +
        '</div>' +
      '</div>';
  }

  function cascadeHTML(attempts) {
    return (attempts || []).map(function (a, i) {
      return attemptRow(a, i, i === attempts.length - 1);
    }).join('');
  }

  function metaChip(k, v) {
    return '<div class="meta-chip"><span class="k">' + esc(k) + '</span><span class="v">' + esc(v) + '</span></div>';
  }

  function tileHTML(t) {
    return '<div class="tile">' +
      '<div class="tile-label">' + esc(t.label) + '</div>' +
      '<div class="tile-row"><div class="tile-value" style="color:' + (t.color || 'var(--g900)') + '">' + esc(t.value) + '</div>' +
      '<div class="tile-unit">' + esc(t.unit || '') + '</div></div>' +
      (t.sub ? '<div class="tile-sub">' + esc(t.sub) + '</div>' : '') +
    '</div>';
  }

  // ------------------------------------------------------------ шапка и меню

  function renderChrome() {
    document.documentElement.setAttribute('data-rc-theme', ui.theme);
    setText('btnTheme', ui.theme === 'dark' ? 'Светлая тема' : 'Тёмная тема');

    var h = srv.health || {};
    setText('hGate', (srv.state && srv.state.gateway) || '—');
    setText('hMerchant', (srv.state && srv.state.merchant) || '—');
    setText('hStrategy', h.strategy ? String(h.strategy).replace(/_/g, ' ') : '—');
    setText('hDecisions', F.fi(h.decisions_count || 0));
    setText('hVersion', h.version || '—');
    setText('hSnapshot', h.snapshot_loaded ? 'snapshot_loaded' : 'no_snapshot');

    var pill = el('hPill');
    var ok = !!h.snapshot_loaded;
    pill.style.background = ok ? 'var(--posq)' : 'var(--negq)';
    pill.style.color = ok ? 'var(--pos)' : 'var(--neg)';
    pill.querySelector('.dot').style.background = ok ? 'var(--pos)' : 'var(--neg)';

    var badges = {
      overview: srv.snapshot ? String(srv.snapshot.providers.length) : '',
      sim: ui.runs.length ? String(ui.runs.length) : '',
      decisions: srv.overview ? F.fi(srv.overview.total) : '',
      context: ''
    };
    setHTML('nav', NAV.map(function (n) {
      var active = ui.page === n.id ? ' is-active' : '';
      return '<button type="button" class="rc-nav-item' + active + '" data-act="nav" data-id="' + n.id + '">' +
        '<span class="rc-nav-rail"></span>' +
        '<span class="rc-nav-label">' + esc(n.label) + '</span>' +
        '<span class="rc-nav-badge">' + esc(badges[n.id]) + '</span>' +
      '</button>';
    }).join(''));

    var rows = providers().map(function (p) {
      var d = diagnose(p);
      return { name: p.name, score: d.score, why: d.why, color: TONE_COLOR[d.tone] };
    }).sort(function (a, b) { return b.score - a.score; });
    setHTML('risks', rows.length ? rows.map(function (r) {
      return '<div class="rc-risk">' +
        '<div class="rc-risk-head">' +
          '<span class="dot" style="background:' + r.color + '"></span>' +
          '<span class="rc-risk-name">' + esc(r.name) + '</span>' +
          '<span class="rc-risk-score" style="color:' + r.color + '">' + r.score + '</span>' +
        '</div>' +
        '<div class="rc-risk-why">' + esc(r.why) + '</div>' +
      '</div>';
    }).join('') : '<div class="rc-risk-why">Нет данных — снапшот не загружен.</div>');
  }

  function renderLegends() {
    var list = providers();
    var html = list.map(function (p) {
      return '<div class="legend-item"><span class="swatch" style="background:' + p.color + '"></span>' + esc(p.name) + '</div>';
    }).join('');
    Array.prototype.forEach.call(document.querySelectorAll('[data-legend]'), function (n) { n.innerHTML = html; });
  }

  // ------------------------------------------------------------------ Обзор

  function renderOverview() {
    var ov = srv.overview;
    var list = providers();
    var buckets = ov.timeline.buckets;
    var B = buckets.length;

    setText('nowLabel', hhmmss(new Date().toISOString()));
    setText('stackNote', ov.timeline.bucket_seconds
      ? 'GET /analytics/overview · корзина ' + Math.round(ov.timeline.bucket_seconds / 60) + ' мин · selected_provider'
      : 'GET /analytics/overview · выборка пуста');

    var scope = hasFilters() ? 'по текущим фильтрам' : 'вся выборка';
    setHTML('tiles', [
      { label: 'Решений в базе', value: F.fi(srv.health.decisions_count), sub: 'retention ' + srv.health.retention_hours + 'h · SQLite' },
      { label: 'Approve rate', value: ov.total ? (ov.approved_count / ov.total * 100).toFixed(1) + '%' : '—',
        color: 'var(--pos)', sub: 'по simulated_result, не по HTTP' },
      { label: 'no_provider', value: F.fi(ov.outcomes.no_provider), color: 'var(--neg)', sub: 'валидный исход, отвечает 200' },
      { label: 'Средний latency', value: ov.avg_latency_sec === null ? '—' : String(ov.avg_latency_sec), unit: 'сек', sub: scope }
    ].map(tileHTML).join(''));

    renderStackChart(list, buckets, B);

    setHTML('provRows', list.map(function (p) {
      var d = diagnose(p);
      var dot = p.status === 'active' ? 'var(--pos)' : 'var(--g500)';
      var driftColor = Math.abs(p.drift) > 3 ? 'var(--warn)' : 'var(--g600)';
      var dailyColor = p.dailyPct === null ? 'var(--g500)'
        : p.dailyPct > 0.9 ? 'var(--neg)' : p.dailyPct > 0.7 ? 'var(--warn)' : 'var(--pos)';
      var conv = p.observed === null ? p.passportConversion : p.observed;
      var convColor = conv > 0.85 ? 'var(--pos)' : conv > 0.7 ? 'var(--warn)' : 'var(--neg)';

      return '<div class="trow g-prov">' +
        '<div style="min-width:0;padding-right:12px">' +
          '<div class="prov-name"><span class="dot" style="width:8px;height:8px;background:' + dot + '"></span><b>' + esc(p.name) + '</b></div>' +
          '<div class="prov-code">' + esc(p.status) + ' · ' + p.requisites + ' рекв.</div>' +
        '</div>' +
        '<div class="cell-share">' +
          '<div class="share-nums">' +
            '<span class="share-fact">' + p.shareFact.toFixed(1) + '%</span>' +
            '<span class="share-target">/ ' + p.target + '%</span>' +
            '<span class="share-drift" style="color:' + driftColor + '">' + (p.drift > 0 ? '+' : '') + p.drift.toFixed(1) + '</span>' +
          '</div>' +
          '<div class="bar">' +
            '<div class="bar-fill" style="background:' + p.color + ';width:' + Math.min(100, p.shareFact * 2).toFixed(1) + '%"></div>' +
            '<div class="bar-tick" style="left:' + Math.min(100, p.target * 2).toFixed(1) + '%"></div>' +
          '</div>' +
        '</div>' +
        '<div class="cell-ip"><div class="n">' + p.inProgressCount + ' опер.</div><div class="s">' + F.fm(p.inProgressAmount) + '</div></div>' +
        '<div class="cell-daily">' +
          '<div class="daily-nums"><span class="a">' + F.fmk(p.dailyUsed) + '</span><span class="b">/ ' +
            (p.dailyLimit ? F.fmk(p.dailyLimit) : 'без лимита') + '</span></div>' +
          '<div class="bar-flat"><div style="background:' + dailyColor + ';width:' +
            (p.dailyPct === null ? 0 : Math.min(100, p.dailyPct * 100)).toFixed(1) + '%"></div></div>' +
        '</div>' +
        '<div class="spark-wrap"><canvas class="spark-canvas" width="56" height="20"></canvas></div>' +
        '<div class="ta-r mono" style="font-size:13px;font-weight:600;color:' + convColor + '" title="' +
          (p.observed === null ? 'conversion_24h из снапшота' : 'observed_conversion по ' + p.attempts + ' попыткам') + '">' +
          (conv === null || conv === undefined ? '—' : (conv * 100).toFixed(1) + '%') +
          (p.observed === null ? '<span style="color:var(--g500)">*</span>' : '') + '</div>' +
        '<div class="ta-r mono" style="font-size:13px;color:var(--g800)">' + p.latency + 's</div>' +
        (d.text ? '<div class="prov-alert" style="background:' + TONE_BG[d.tone] + ';color:' + TONE_COLOR[d.tone] + '">' +
          '<span class="dot" style="background:' + TONE_COLOR[d.tone] + '"></span><span class="pretty">' + esc(d.text) + '</span></div>' : '') +
      '</div>';
    }).join(''));
    renderSparklines(list);

    renderDonut(ov);

    var hist = ov.attempt_histogram;
    var base = hist.length ? hist[0].count : 0;
    setHTML('cascade', hist.length ? hist.map(function (h, i) {
      var w = base ? h.count / base * 100 : 0;
      return '<div class="cascade-row">' +
        '<div class="l"><span>Попытка ' + h.attempt_no + '</span><span>' + F.fi(h.count) + ' · ' + w.toFixed(0) + '%</span></div>' +
        '<div class="cascade-bar"><div style="background:' + COLORS[i % COLORS.length] + ';width:' + w.toFixed(1) + '%"></div></div>' +
      '</div>';
    }).join('') : '<div class="rc-risk-why">Попыток в выборке нет.</div>');

    var skips = (srv.report && srv.report.skip_reasons) || {};
    var skipKeys = Object.keys(skips).sort(function (a, b) { return skips[b] - skips[a]; });
    show('skipCard', skipKeys.length > 0);
    setHTML('skipRows', skipKeys.map(function (k) {
      return '<div class="row"><span class="k">' + esc(k) + '</span><span class="v">' + F.fi(skips[k]) + '</span></div>';
    }).join(''));

    var recs = (srv.report && srv.report.recommendations) || [];
    show('recCard', recs.length > 0);
    setHTML('recRows', recs.map(function (r) { return '<li>' + esc(r) + '</li>'; }).join(''));
  }

  // Стопка площадей по корзинам: каждая серия рисуется как кумулятивная сумма
  // поверх предыдущих (fill:'-1' заливает промежуток между соседними линиями),
  // порядок датасетов — снизу вверх в порядке providers().
  function renderStackChart(list, buckets, B) {
    var canvas = el('chartStack');
    if (!canvas) return;
    if (!B) { RCCharts.destroy('stack'); return; }

    var labels = buckets.map(function (b) { return hhmm(b.at); });
    var cum = new Array(B).fill(0);
    var datasets = list.map(function (p, idx) {
      // data — кумулятивная сумма (нужна для заливки fill:'-1' между
      // соседними линиями); raw — реальное число решений провайдера в
      // корзине, показывается в тултипе вместо накопленного.
      var raw = buckets.map(function (bucket) { return (bucket.by_provider || {})[p.name] || 0; });
      var data = raw.map(function (v, i) { cum[i] += v; return cum[i]; });
      return {
        label: p.name, data: data, raw: raw,
        borderColor: p.color, borderWidth: 1,
        backgroundColor: RCCharts.hexToRgba(p.color, 0.85),
        fill: idx === 0 ? 'origin' : '-1',
        pointRadius: 0, tension: 0
      };
    });

    RCCharts.upsert('stack', canvas, {
      type: 'line',
      data: { labels: labels, datasets: datasets },
      options: RCCharts.timeSeriesOptions({
        scales: {
          x: { grid: { display: false }, ticks: RCCharts.axisTicks() },
          y: {
            stacked: true, min: 0,
            grid: RCCharts.axisGrid(), border: { display: false },
            ticks: RCCharts.axisTicks({ precision: 0 })
          }
        },
        plugins: {
          legend: { display: false },
          tooltip: {
            backgroundColor: RCCharts.cssVar('--g900'),
            titleColor: RCCharts.cssVar('--l2'), bodyColor: RCCharts.cssVar('--l2'),
            padding: 8, cornerRadius: 6,
            callbacks: {
              label: function (ctx) { return ctx.dataset.label + ': ' + ctx.dataset.raw[ctx.dataIndex]; }
            }
          }
        }
      })
    });
  }

  // Спарклайны в колонке «Пульс»: строки таблицы каждый раз строятся заново
  // через innerHTML, поэтому canvas тоже каждый раз новый — upsertMany сам
  // убивает предыдущий набор инстансов перед созданием текущего.
  function renderSparklines(list) {
    var canvases = document.querySelectorAll('#provRows .spark-canvas');
    RCCharts.upsertMany('spark:', canvases, function (canvas, i) {
      var p = list[i];
      return {
        type: 'line',
        data: {
          labels: p.series.map(function (_, j) { return j; }),
          datasets: [{
            data: p.series, borderColor: p.color, borderWidth: 1.5,
            pointRadius: 0, tension: 0, fill: false
          }]
        },
        options: {
          responsive: false, maintainAspectRatio: false, animation: false,
          layout: { padding: 1 },
          plugins: { legend: { display: false }, tooltip: { enabled: false } },
          scales: {
            x: { display: false },
            y: { display: false, min: 0 }
          }
        }
      };
    });
  }

  function renderDonut(ov) {
    var canvas = el('donutChart');
    setText('donutPct', ov.total ? (ov.approved_count / ov.total * 100).toFixed(0) + '%' : '—');

    var outcomes = OUTCOME_KEYS.map(function (k) { return { key: k, count: ov.outcomes[k] || 0, tone: F.tone(k) }; });
    setHTML('outcomes', outcomes.map(function (o) {
      return '<div class="outcome"><span class="swatch" style="background:' + o.tone.fg + '"></span>' +
        '<span class="k">' + esc(o.key) + '</span><span class="v">' + F.fi(o.count) + '</span></div>';
    }).join(''));

    if (!canvas) return;
    if (!ov.total) { RCCharts.destroy('donut'); return; }

    RCCharts.upsert('donut', canvas, {
      type: 'doughnut',
      data: {
        labels: outcomes.map(function (o) { return o.key; }),
        datasets: [{
          data: outcomes.map(function (o) { return o.count; }),
          backgroundColor: outcomes.map(function (o) { return o.tone.fg; }),
          borderColor: RCCharts.cssVar('--l1'), borderWidth: 2
        }]
      },
      options: {
        responsive: true, maintainAspectRatio: false, animation: false,
        cutout: '64%',
        plugins: {
          legend: { display: false },
          tooltip: {
            backgroundColor: RCCharts.cssVar('--g900'),
            titleColor: RCCharts.cssVar('--l2'), bodyColor: RCCharts.cssVar('--l2'),
            padding: 8, cornerRadius: 6,
            callbacks: {
              label: function (ctx) {
                var pct = ov.total ? (ctx.parsed / ov.total * 100).toFixed(1) : '0.0';
                return ctx.label + ': ' + ctx.parsed + ' (' + pct + '%)';
              }
            }
          }
        }
      }
    });
  }

  // ------------------------------------------------------------- Симулятор

  function renderSim() {
    var single = ui.mode === 'single';
    Array.prototype.forEach.call(document.querySelectorAll('#modeSeg button'), function (b) {
      b.classList.toggle('is-active', b.getAttribute('data-id') === ui.mode);
    });
    show('simSingle', single);
    show('simBatch', !single);
    setText('btnRun', single ? 'POST /operations' : 'POST /operations/batch');

    syncField('fAmount', ui.amount);
    syncField('fBank', ui.bank);
    syncField('fBrand', ui.brand);
    syncField('fPhone', ui.phone);
    syncField('fBankName', ui.bankName);
    syncField('fBatch', ui.batchText);
    setHTML('bankList', allBanks().map(function (b) {
      return '<option value="' + esc(b) + '"></option>';
    }).join(''));
    setText('nextOpId', nextOperationId(0));

    show('runsEmpty', ui.runs.length === 0);
    setHTML('runsList', ui.runs.map(function (r, i) {
      var active = ui.run === r ? ' is-active' : '';
      return '<div class="run-row' + active + '" data-act="run" data-id="' + i + '">' +
        '<span class="dot" style="background:' + F.tone(r.decision.simulated_result).fg + '"></span>' +
        '<span class="t">' + esc(hhmm(r.sent.created_at)) + '</span>' +
        '<span class="p">' + esc((r.decision.selected_provider || 'no_provider') + ' · ' + r.decision.simulated_result) + '</span>' +
        '<span class="a">' + F.fi(r.sent.amount) + '</span>' +
      '</div>';
    }).join(''));

    var run = ui.run;
    show('resCard', !!run);
    show('resEmpty', !run && !ui.batchRes);
    if (run) {
      var d = run.decision;
      var t = F.tone(d.simulated_result);
      var pill = el('resPill');
      pill.style.background = t.bg;
      pill.style.color = t.fg;
      pill.querySelector('.dot').style.background = t.fg;
      setText('resResult', d.simulated_result);
      setText('resProvider', d.selected_provider || '—');
      setText('resLatency', d.latency_sec === null ? 'null' : d.latency_sec + 's');
      setText('resAttempts', String(d.attempts.length));
      setHTML('resMeta',
        metaChip('operation_id', d.operation_id) +
        metaChip('amount', F.fi(run.sent.amount)) +
        metaChip('bank', run.sent.bank) +
        metaChip('card_brand', run.sent.card_brand || 'null') +
        metaChip('sbp.phone', run.sent.payout_requisite.sbp.phone) +
        metaChip('created_at', hhmmss(run.sent.created_at)));
      setHTML('resCascade', cascadeHTML(d.attempts));
    }

    show('batchCard', !!ui.batchRes);
    if (ui.batchRes) {
      setText('batchProcessed', String(ui.batchRes.processed));
      var fail = el('batchFail');
      fail.textContent = ui.batchRes.failLabel;
      fail.style.color = ui.batchRes.failColor;
      setHTML('batchRows', ui.batchRes.rows.map(function (b) {
        var bt = F.tone(b.result);
        return '<div class="trow g-batch">' +
          '<div class="mono" style="color:var(--g600)">' + b.i + '</div>' +
          '<div style="color:var(--g900);white-space:nowrap;overflow:hidden;text-overflow:ellipsis">' + esc(b.provider) + '</div>' +
          '<div><span class="tag" style="background:' + bt.bg + ';color:' + bt.fg + '">' + esc(b.result) + '</span></div>' +
          '<div class="ta-r mono" style="color:var(--g800)">' + F.fi(b.amount) + '</div>' +
          '<div class="ta-r mono" style="color:var(--g700)">' + esc(b.latency) + '</div>' +
        '</div>';
      }).join(''));
    }
  }

  // -------------------------------------------------------------- Аналитика

  function renderDecisions() {
    var ov = srv.overview;
    var rep = srv.report;
    var page = srv.decisions;
    var list = providers();
    var buckets = ov.timeline.buckets;
    var B = buckets.length;

    syncField('fSince', ui.filter.since);
    syncField('fUntil', ui.filter.until);
    syncField('fMerchant', ui.filter.merchant);
    syncField('fGate', ui.filter.gate);
    syncField('fProvider', ui.filter.provider);
    syncField('fLimit', String(ui.limit));
    show('providerWarn', !!ui.filter.provider);

    var bad = ov.outcomes.rejected + ov.outcomes.expired + ov.outcomes.no_provider;
    var apRate = ov.total ? ov.approved_count / ov.total : 0;
    setHTML('repTiles', [
      { label: 'Решений в выборке', value: F.fi(ov.total) },
      { label: 'Approve rate', value: ov.total ? (apRate * 100).toFixed(1) + '%' : '—',
        color: apRate > 0.85 ? 'var(--pos)' : 'var(--warn)' },
      { label: 'Одобренный объём', value: F.fmk(ov.approved_amount) },
      { label: 'Неуспешных исходов', value: F.fi(bad), color: bad ? 'var(--neg)' : 'var(--g900)' },
      { label: 'Средний latency', value: ov.avg_latency_sec === null ? '—' : String(ov.avg_latency_sec), unit: 'сек' }
    ].map(tileHTML).join(''));

    setText('rateNote', 'approved_by_provider / by_provider' +
      (ov.timeline.bucket_seconds ? ' · корзина ' + Math.round(ov.timeline.bucket_seconds / 60) + ' мин' : ''));

    renderRateChart(list, buckets, B);

    var dist = rep.distribution || {};
    var vol = rep.volume_distribution || {};
    var att = rep.attempt_distribution || {};
    setHTML('repRows', list.map(function (p) {
      var d = dist[p.name] || {};
      var v = vol[p.name] || {};
      var a = att[p.name] || {};
      var conv = a.observed_conversion;
      var convColor = conv === null || conv === undefined ? 'var(--g500)'
        : conv > 0.85 ? 'var(--pos)' : conv > 0.7 ? 'var(--warn)' : 'var(--neg)';
      var dev = d.deviation_pp;
      return '<div class="trow g-rep">' +
        '<div style="display:flex;align-items:center;gap:8px;min-width:0">' +
          '<span class="swatch" style="width:8px;height:8px;background:' + p.color + '"></span>' +
          '<span style="color:var(--g900);font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">' + esc(p.name) + '</span>' +
        '</div>' +
        '<div class="ta-r mono" style="color:var(--g900)">' + F.fi(d.count || 0) + '</div>' +
        '<div class="ta-r mono" style="color:var(--g700)">' + pct(d.share_pct) + ' / ' + (d.target_pct === undefined ? '—' : d.target_pct + '%') + '</div>' +
        '<div class="ap-cell"><div class="row">' +
          '<div class="bar-flat"><div style="background:' + convColor + ';width:' +
            ((conv || 0) * 100).toFixed(1) + '%"></div></div>' +
          '<span class="val">' + (conv === null || conv === undefined ? '—' : (conv * 100).toFixed(1) + '%') + '</span>' +
        '</div></div>' +
        '<div class="ta-r mono" style="color:var(--g800)">' + F.fmk(v.amount || 0) + '</div>' +
        '<div class="ta-r mono" style="color:' + (Math.abs(dev || 0) > 3 ? 'var(--warn)' : 'var(--g700)') + '">' +
          (dev === undefined ? '—' : (dev > 0 ? '+' : '') + dev.toFixed(1)) + '</div>' +
      '</div>';
    }).join(''));

    show('decEmpty', page.items.length === 0);
    setHTML('decRows', page.items.map(function (d) {
      var t = F.tone(d.simulated_result);
      var pips = d.attempts.map(function (a) {
        return '<span class="pip" style="background:' + attemptTone(a).fg + '"></span>';
      }).join('');
      var bg = ui.drawer === d.id ? 'var(--accq)' : 'transparent';
      var color = providerColor(d.selected_provider);
      return '<div class="trow g-dec" data-act="decision" data-id="' + d.id + '" style="background:' + bg + '">' +
        '<div class="mono" style="color:var(--g600)">' + d.id + '</div>' +
        '<div class="mono" style="color:var(--g700)">' + esc(hhmmss(d.created_at)) + '</div>' +
        '<div class="mono" style="color:var(--g800);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;padding-right:10px">' + esc(d.operation_id) + '</div>' +
        '<div class="ta-r mono" style="padding-right:12px;color:var(--g900)">' + F.fi(d.amount) + '</div>' +
        '<div style="color:var(--g800)">' + esc(d.bank || '—') + '</div>' +
        '<div style="display:flex;align-items:center;gap:7px;min-width:0">' +
          '<span class="dot" style="background:' + color + '"></span>' +
          '<span style="color:var(--g900);white-space:nowrap;overflow:hidden;text-overflow:ellipsis">' + esc(d.selected_provider || 'null') + '</span>' +
        '</div>' +
        '<div><span class="tag" style="background:' + t.bg + ';color:' + t.fg + '">' + esc(d.simulated_result) + '</span></div>' +
        '<div class="ta-r mono" style="color:var(--g700)">' + (d.latency_sec === null ? 'null' : d.latency_sec + 's') + '</div>' +
        '<div class="pips">' + pips + '</div>' +
      '</div>';
    }).join(''));

    var end = page.offset + page.items.length;
    setText('pageLabel', page.total
      ? (page.offset + 1) + '–' + end + ' из ' + F.fi(page.total) + ' · offset ' + page.offset
      : '0 из 0');
    setText('nextOffset', page.next_offset === null ? 'null' : String(page.next_offset));
    el('btnPrev').style.opacity = page.offset > 0 ? '1' : '.4';
    el('btnNext').style.opacity = page.next_offset === null ? '.4' : '1';
  }

  // Корзина без попыток провайдера — это null в данных, а не 0 и не
  // пропущенная точка: с null + spanGaps:false (дефолт Chart.js) линия рвётся
  // на пропуске, вместо того чтобы тянуть прямую через период без данных так,
  // будто конверсия там менялась плавно.
  function renderRateChart(list, buckets, B) {
    var canvas = el('chartRate');
    if (!canvas) return;
    if (!B) { RCCharts.destroy('rate'); return; }

    var labels = buckets.map(function (b) { return hhmm(b.at); });
    var datasets = list.map(function (p) {
      var data = buckets.map(function (bucket) {
        var total = (bucket.by_provider || {})[p.name] || 0;
        if (!total) return null;
        var ok = (bucket.approved_by_provider || {})[p.name] || 0;
        return +(ok / total * 100).toFixed(1);
      });
      return {
        label: p.name, data: data, borderColor: p.color, backgroundColor: p.color,
        borderWidth: 2, pointRadius: 0, pointHoverRadius: 4, tension: 0,
        spanGaps: false
      };
    });

    RCCharts.upsert('rate', canvas, {
      type: 'line',
      data: { labels: labels, datasets: datasets },
      options: RCCharts.timeSeriesOptions({
        scales: {
          x: { grid: { display: false }, ticks: RCCharts.axisTicks() },
          y: {
            min: 0, max: 100,
            grid: RCCharts.axisGrid(), border: { display: false },
            ticks: RCCharts.axisTicks({ callback: function (v) { return v + '%'; } })
          }
        },
        plugins: {
          legend: { display: false },
          tooltip: {
            backgroundColor: RCCharts.cssVar('--g900'),
            titleColor: RCCharts.cssVar('--l2'), bodyColor: RCCharts.cssVar('--l2'),
            padding: 8, cornerRadius: 6,
            callbacks: {
              label: function (ctx) {
                return ctx.dataset.label + ': ' + (ctx.parsed.y === null ? 'нет попыток' : ctx.parsed.y + '%');
              }
            }
          }
        }
      })
    });
  }

  function providerColor(name) {
    var found = providers().filter(function (p) { return p.name === name; })[0];
    return found ? found.color : 'var(--g500)';
  }

  // Отчёт собирается из уже загруженных srv.report/srv.overview — без
  // повторного запроса, теми же фильтрами, что сейчас применены на экране.
  function exportReport() {
    var colors = {};
    providers().forEach(function (p) { colors[p.name] = p.color; });

    var html = global.RCReportExport.build({
      report: srv.report,
      overview: srv.overview,
      filters: filterParams(),
      colors: colors,
      generatedAt: new Date().toISOString(),
      meta: { strategy: srv.health && srv.health.strategy, gate: srv.state && srv.state.gateway, merchant: srv.state && srv.state.merchant }
    });
    var stamp = new Date().toISOString().replace(/[:.]/g, '-');
    global.RCReportExport.download(html, 'routing-report-' + stamp + '.html');
    flash('HTML-отчёт сохранён', 'var(--pos)');
  }

  // ---------------------------------------------------------------- Контекст

  function draftFromConfig(config) {
    var outcomes = config.outcomes || {};
    return {
      strategy: config.strategy || '',
      source: outcomes.source || 'deterministic',
      seed: String(outcomes.seed === undefined ? '' : outcomes.seed),
      fallback: config.fallback_provider || '',
      layers: (config.layers || []).slice()
    };
  }

  function renderContext() {
    var draft = ui.cfgDraft;
    var caps = srv.caps;

    fillOptions('cStrategy', caps.strategies.map(function (s) { return { v: s, l: s }; }), draft.strategy);
    syncField('cSource', draft.source);
    syncField('cSeed', draft.seed);
    syncField('cFallback', draft.fallback);
    setText('cRetention', String(srv.health.retention_hours));

    setHTML('layerChips', caps.layers.length ? caps.layers.map(function (l) {
      var on = draft.layers.indexOf(l) >= 0;
      return '<button type="button" class="chip-toggle' + (on ? ' is-on' : '') + '" data-act="layer" data-id="' + esc(l) + '">' +
        '<span class="dot"></span>' + esc(l) + '</button>';
    }).join('') : '<div class="rc-risk-why">Реестр слоёв пуст.</div>');

    var snap = srv.snapshot;
    var rows = [
      ['snapshot_at', snap.snapshot_at || '—'],
      ['providers_count', String(snap.providers.length)],
      ['gateway', snap.gateway],
      ['merchant', snap.merchant],
      ['traffic_percentage', snap.providers.map(function (p) { return p.traffic_percentage + '%'; }).join(' / ')]
    ];
    setHTML('snapRows', rows.map(function (r) {
      return '<div class="row"><span class="k">' + esc(r[0]) + '</span><span class="v">' + esc(r[1]) + '</span></div>';
    }).join(''));

    var h = srv.health;
    var health = [
      ['status', h.status, 'var(--pos)'],
      ['snapshot_loaded', String(h.snapshot_loaded), h.snapshot_loaded ? 'var(--pos)' : 'var(--neg)'],
      ['decisions_count', F.fi(h.decisions_count), 'var(--g900)'],
      ['retention_hours', String(h.retention_hours), 'var(--g900)'],
      ['strategy', String(h.strategy), 'var(--g900)'],
      ['version', String(h.version), 'var(--g900)']
    ];
    setHTML('healthRows', health.map(function (r) {
      return '<div class="row"><span class="k">' + esc(r[0]) + '</span><span class="v" style="color:' + r[2] + '">' + esc(r[1]) + '</span></div>';
    }).join(''));

    setHTML('targets', providers().map(function (p) {
      return '<div>' +
        '<div class="row"><span>' + esc(p.name) + '</span><span>' + p.target + '%</span></div>' +
        '<div class="bar-flat"><div style="background:' + p.color + ';width:' + Math.min(100, p.target * 2) + '%"></div></div>' +
      '</div>';
    }).join(''));
  }

  // ------------------------------------------------------------------ Шторка

  function drawerItem() {
    if (ui.drawer === null || !srv.decisions) return null;
    return srv.decisions.items.filter(function (x) { return x.id === ui.drawer; })[0] || null;
  }

  function renderDrawer() {
    var d = drawerItem();
    show('drawer', !!d);
    if (!d) return;

    var t = F.tone(d.simulated_result);
    setText('drId', String(d.id));
    setText('drOpId', d.operation_id);
    var pill = el('drPill');
    pill.style.background = t.bg;
    pill.style.color = t.fg;
    pill.querySelector('.dot').style.background = t.fg;
    setText('drResult', d.simulated_result);
    setText('drProvider', d.selected_provider || 'null');

    var meta = [
      ['amount', F.fm(d.amount)],
      ['latency_sec', d.latency_sec === null ? 'null' : String(d.latency_sec)],
      ['bank', d.bank || '—'],
      ['card_brand', d.card_brand || 'null'],
      ['merchant', d.merchant],
      ['gate', d.gate],
      ['created_at', d.created_at],
      ['attempts', String(d.attempts.length)]
    ];
    setHTML('drMeta', meta.map(function (m) {
      return '<div class="cell"><div class="k">' + esc(m[0]) + '</div><div class="v">' + esc(m[1]) + '</div></div>';
    }).join(''));
    setHTML('drCascade', cascadeHTML(d.attempts));
    setText('drJson', JSON.stringify(d, null, 2));
  }

  function stepDrawer(delta) {
    if (!srv.decisions) return;
    var items = srv.decisions.items;
    var i = items.findIndex(function (x) { return x.id === ui.drawer; });
    if (i < 0) return;
    var next = i + delta;
    if (next < 0 || next >= items.length) return;
    ui.drawer = items[next].id;
    render();
  }

  // ------------------------------------------------------------------ render

  function renderGate() {
    var g = srv.gate;
    show('gate', !!g);
    if (!g) return;
    setText('gateTitle', g.title);
    if (g.kind === 'no_snapshot') {
      setText('gateText', 'Сервис поднят и отвечает, но провайдеров ему ещё не давали: /state, /report и /analytics вернут 409 no_snapshot. Загрузите снапшот и конфиг одним запросом:');
      var code = el('gateCode');
      code.hidden = false;
      code.textContent = 'ruby -rjson -ryaml -e \'\n  snapshot = JSON.parse(File.read("reference/data/providers.json"))\n  config   = YAML.safe_load_file("config/routing.yml")\n  print JSON.generate("snapshot" => snapshot, "config" => config)\' \\\n  | curl -sS -X POST -H \'Content-Type: application/json\' --data-binary @- \\\n         ' + (Api.base || location.origin) + '/bootstrap';
    } else {
      setText('gateText', (g.error && g.error.message) || 'Не удалось получить ответ от сервиса. Проверьте, что bin/serve запущен.');
      el('gateCode').hidden = true;
    }
  }

  function render() {
    renderChrome();
    renderGate();

    var ready = !srv.gate && ui.booted;
    Array.prototype.forEach.call(document.querySelectorAll('.rc-page'), function (n) {
      n.hidden = !ready || n.getAttribute('data-page') !== ui.page;
    });
    if (!ready) { show('drawer', false); return; }

    renderLegends();
    if (ui.page === 'overview') renderOverview();
    if (ui.page === 'sim') renderSim();
    if (ui.page === 'decisions') renderDecisions();
    if (ui.page === 'context') renderContext();
    renderDrawer();
  }

  // ----------------------------------------------------------------- действия

  function nextOperationId(bump) {
    return 'console_' + Date.now().toString(36) + '_' + (ui.seq + (bump || 0));
  }

  function buildOperation(raw) {
    var op = {
      operation_id: raw.operation_id || nextOperationId(0),
      created_at: raw.created_at || new Date().toISOString(),
      amount: raw.amount,
      bank: raw.bank,
      card_brand: raw.card_brand === undefined ? null : raw.card_brand,
      payout_requisite: raw.payout_requisite || { sbp: { phone: ui.phone, bank_name: ui.bankName } }
    };
    ui.seq += 1;
    return op;
  }

  function runSingle() {
    var amount = parseInt(ui.amount || '0', 10);
    if (!amount || amount < 1) {
      flash('amount должен быть целым ≥ 1 — запрос не отправлен', 'var(--neg)');
      return;
    }
    var op = buildOperation({
      amount: amount, bank: ui.bank, card_brand: ui.brand || null
    });
    busy(true);
    Api.route(op).then(function (decision) {
      ui.run = { sent: op, decision: decision };
      ui.runs = [ui.run].concat(ui.runs).slice(0, 8);
      ui.batchRes = null;
      flash('200 · simulated_result = ' + decision.simulated_result,
        decision.simulated_result === 'approved' ? 'var(--pos)' : 'var(--warn)');
      return reload();
    }).catch(function (e) {
      flashError(e);
      busy(false);
    });
  }

  // Батч уходит одним запросом; сервис применяет операции строго по порядку и
  // на первой невалидной отвечает 400 с details.failed_index — применённые до
  // неё остаются в базе.
  function runBatch() {
    var parsed;
    try {
      parsed = JSON.parse(ui.batchText);
    } catch (e) {
      flash('невалидный JSON — запрос не отправлен', 'var(--neg)');
      return;
    }
    if (!Array.isArray(parsed) || !parsed.length) {
      flash('нужен непустой массив операций', 'var(--neg)');
      return;
    }

    var ops = parsed.map(buildOperation);
    busy(true);
    Api.routeBatch(ops).then(function (res) {
      ui.run = null;
      ui.batchRes = {
        processed: res.processed,
        failLabel: 'все операции применены',
        failColor: 'var(--pos)',
        rows: res.decisions.map(function (d, i) {
          return {
            i: i, provider: d.selected_provider || '—', result: d.simulated_result,
            amount: ops[i].amount, latency: d.latency_sec === null ? 'null' : d.latency_sec + 's'
          };
        })
      };
      flash('200 · processed ' + res.processed, 'var(--pos)');
      return reload();
    }).catch(function (e) {
      var details = e.details || {};
      ui.run = null;
      ui.batchRes = {
        processed: details.processed || 0,
        failLabel: details.failed_index === undefined
          ? e.message
          : 'failed_index ' + details.failed_index + ' · применённые остались',
        failColor: 'var(--neg)',
        rows: []
      };
      flashError(e);
      return reload();
    });
  }

  function applyConfig() {
    var draft = ui.cfgDraft;
    var config = JSON.parse(JSON.stringify(srv.config));
    config.strategy = draft.strategy;
    config.layers = draft.layers;
    config.fallback_provider = draft.fallback;
    config.outcomes = Object.assign({}, config.outcomes, {
      source: draft.source,
      seed: draft.seed === '' ? 42 : Number(draft.seed)
    });

    busy(true);
    Api.applyConfig(config).then(function () {
      ui.cfgDraft = null;
      ui.offset = 0;
      flash('POST /config 200 · state и decisions сброшены', 'var(--warn)');
      return reload();
    }).catch(function (e) { flashError(e); busy(false); });
  }

  function doBootstrap() {
    busy(true);
    Promise.all([Api.snapshot(), Api.config()]).then(function (r) {
      return Api.bootstrap(r[0], r[1]);
    }).then(function () {
      ui.cfgDraft = null;
      ui.offset = 0;
      flash('POST /bootstrap 200 · снапшот и конфиг перезагружены', 'var(--pos)');
      return reload();
    }).catch(function (e) { flashError(e); busy(false); });
  }

  function doReset() {
    busy(true);
    Api.reset().then(function () {
      ui.offset = 0;
      flash('POST /reset 200 · state восстановлен из снапшота', 'var(--warn)');
      return reload();
    }).catch(function (e) { flashError(e); busy(false); });
  }

  // ------------------------------------------------------------------- связки

  function bindInput(id, apply, sanitize) {
    var node = el(id);
    if (!node) return;
    var event = node.tagName === 'SELECT' ? 'change' : 'input';
    node.addEventListener(event, function () {
      var value = sanitize ? sanitize(node.value) : node.value;
      if (value !== node.value) node.value = value;
      apply(value);
    });
  }

  var digits = function (v) { return v.replace(/[^0-9]/g, ''); };

  function bind() {
    el('btnTheme').addEventListener('click', function () {
      ui.theme = ui.theme === 'dark' ? 'light' : 'dark';
      try { localStorage.setItem(THEME_KEY, ui.theme); } catch (e) { /* приватный режим */ }
      render();
    });
    el('btnRefresh').addEventListener('click', function () { reload(); });
    el('gateRetry').addEventListener('click', function () { reload(); });
    el('btnGoSim').addEventListener('click', function () { ui.page = 'sim'; render(); });

    bindInput('fAmount', function (v) { ui.amount = v; }, digits);
    bindInput('fBank', function (v) { ui.bank = v; });
    bindInput('fBrand', function (v) { ui.brand = v; });
    bindInput('fPhone', function (v) { ui.phone = v; });
    bindInput('fBankName', function (v) { ui.bankName = v; });
    bindInput('fBatch', function (v) { ui.batchText = v; });
    el('btnRun').addEventListener('click', function () {
      if (ui.mode === 'single') runSingle(); else runBatch();
    });

    ['fSince:since', 'fUntil:until', 'fMerchant:merchant', 'fGate:gate', 'fProvider:provider']
      .forEach(function (pair) {
        var parts = pair.split(':');
        var node = el(parts[0]);
        node.addEventListener('change', function () {
          ui.filter[parts[1]] = node.value;
          ui.offset = 0;
          ui.drawer = null;
          reload();
        });
      });
    el('fLimit').addEventListener('change', function () {
      ui.limit = Number(el('fLimit').value);
      ui.offset = 0;
      reload();
    });
    el('btnExportReport').addEventListener('click', exportReport);
    el('btnClearFilters').addEventListener('click', function () {
      ui.filter = { since: '', until: '', merchant: '', gate: '', provider: '' };
      ui.offset = 0;
      ui.drawer = null;
      reload();
    });
    el('btnPrev').addEventListener('click', function () {
      if (!srv.decisions || srv.decisions.offset === 0) return;
      ui.offset = Math.max(0, srv.decisions.offset - ui.limit);
      reload();
    });
    el('btnNext').addEventListener('click', function () {
      if (!srv.decisions || srv.decisions.next_offset === null) return;
      ui.offset = srv.decisions.next_offset;
      reload();
    });

    bindInput('cStrategy', function (v) { ui.cfgDraft.strategy = v; });
    bindInput('cSource', function (v) { ui.cfgDraft.source = v; });
    bindInput('cSeed', function (v) { ui.cfgDraft.seed = v; }, digits);
    bindInput('cFallback', function (v) { ui.cfgDraft.fallback = v; });
    el('btnApplyConfig').addEventListener('click', applyConfig);
    el('btnBootstrap').addEventListener('click', doBootstrap);
    el('btnReset').addEventListener('click', doReset);

    el('drClose').addEventListener('click', function () { ui.drawer = null; render(); });
    el('drawerScrim').addEventListener('click', function () { ui.drawer = null; render(); });
    el('drPrev').addEventListener('click', function () { stepDrawer(-1); });
    el('drNext').addEventListener('click', function () { stepDrawer(1); });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && ui.drawer !== null) { ui.drawer = null; render(); }
    });

    // Списки перерисовываются целиком, поэтому обработчики — делегированием.
    document.addEventListener('click', function (e) {
      var node = e.target.closest('[data-act]');
      if (!node) return;
      var id = node.getAttribute('data-id');
      switch (node.getAttribute('data-act')) {
        case 'nav': ui.page = id; ui.drawer = null; render(); break;
        case 'mode': ui.mode = id; render(); break;
        case 'run': ui.run = ui.runs[Number(id)]; ui.batchRes = null; render(); break;
        case 'decision': ui.drawer = Number(id); render(); break;
        case 'layer': {
          var layers = ui.cfgDraft.layers;
          var at = layers.indexOf(id);
          if (at >= 0) layers.splice(at, 1); else layers.push(id);
          render();
          break;
        }
      }
    });
  }

  function init() {
    try {
      var saved = localStorage.getItem(THEME_KEY);
      if (saved === 'dark' || saved === 'light') ui.theme = saved;
    } catch (e) { /* приватный режим */ }

    fillOptions('fLimit', LIMITS.map(function (l) { return { v: l, l: l }; }), String(ui.limit));
    bind();
    render();

    // Значения фильтров merchant/gate известны только после /state.
    reload().then(function () {
      if (!srv.state) return;
      fillOptions('fMerchant', [{ v: '', l: 'все' }, { v: srv.state.merchant, l: srv.state.merchant }], ui.filter.merchant);
      fillOptions('fGate', [{ v: '', l: 'все' }, { v: srv.state.gateway, l: srv.state.gateway }], ui.filter.gate);
      fillOptions('fProvider', [{ v: '', l: 'все' }].concat(providers().map(function (p) {
        return { v: p.name, l: p.name };
      })), ui.filter.provider);
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})(window);
