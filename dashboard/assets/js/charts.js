/* Тонкая обёртка над Chart.js (vendor/chart.umd.min.js).
 *
 * Раньше графики консоли были собственноручным SVG (polygon/polyline),
 * который на канале approve rate тихо соединял точки через пустые корзины
 * прямой линией — визуально показывая изменение там, где данных не было
 * вовсе. Chart.js с явным `null` в данных и `spanGaps: false` рвёт линию
 * на пропуске, а не подрисовывает его.
 *
 * app.js каждый рендер пересобирает HTML целиком (innerHTML), поэтому старые
 * canvas-элементы графиков в table/карточках исчезают из DOM, а привязанные
 * к ним инстансы Chart.js — нет: без explicit destroy() они утекают и
 * продолжают держать detached-canvas в памяти. upsert()/upsertMany() всегда
 * убивают предыдущий инстанс перед созданием нового.
 */
(function (global) {
  'use strict';

  var registry = {};

  function cssVar(name) {
    return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  }

  function hexToRgba(hex, alpha) {
    var m = /^#?([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(hex);
    if (!m) return hex;
    var r = parseInt(m[1], 16), g = parseInt(m[2], 16), b = parseInt(m[3], 16);
    return 'rgba(' + r + ',' + g + ',' + b + ',' + alpha + ')';
  }

  function upsert(key, canvas, config) {
    if (registry[key]) registry[key].destroy();
    if (!canvas) { delete registry[key]; return null; }
    var chart = new Chart(canvas, config);
    registry[key] = chart;
    return chart;
  }

  function destroy(key) {
    if (registry[key]) { registry[key].destroy(); delete registry[key]; }
  }

  // Спарклайны пересоздаются целиком: строки таблицы провайдеров каждый раз
  // строятся заново через innerHTML, старых canvas по стабильному ключу нет.
  function upsertMany(prefix, canvases, configFor) {
    Object.keys(registry).forEach(function (key) {
      if (key.indexOf(prefix) === 0) destroy(key);
    });
    Array.prototype.forEach.call(canvases, function (canvas, i) {
      upsert(prefix + i, canvas, configFor(canvas, i));
    });
  }

  var FONT_MONO = "'Source Code Pro', ui-monospace, monospace";

  function axisGrid() {
    return { color: cssVar('--g300'), drawTicks: false };
  }

  function axisTicks(extra) {
    return Object.assign({
      color: cssVar('--g600'),
      font: { family: FONT_MONO, size: 11 },
      maxRotation: 0,
      autoSkipPadding: 12
    }, extra || {});
  }

  // Общий каркас line-графика (обзор/аналитика): своя легенда и подписи осей
  // консоль рисует сама (см. renderLegends в app.js), поэтому легенда Chart.js
  // выключена — незачем дублировать один и тот же список цветов дважды.
  function timeSeriesOptions(overrides) {
    return Object.assign({
      responsive: true,
      maintainAspectRatio: false,
      animation: false,
      interaction: { mode: 'index', intersect: false },
      plugins: {
        legend: { display: false },
        tooltip: {
          backgroundColor: cssVar('--g900'),
          titleColor: cssVar('--l2'),
          bodyColor: cssVar('--l2'),
          titleFont: { family: FONT_MONO, size: 11 },
          bodyFont: { family: FONT_MONO, size: 11 },
          padding: 8,
          cornerRadius: 6,
          displayColors: true,
          boxPadding: 3
        }
      },
      scales: {
        x: { grid: { display: false }, ticks: axisTicks() },
        y: { grid: axisGrid(), border: { display: false }, ticks: axisTicks() }
      }
    }, overrides || {});
  }

  global.RCCharts = {
    cssVar: cssVar,
    hexToRgba: hexToRgba,
    upsert: upsert,
    destroy: destroy,
    upsertMany: upsertMany,
    timeSeriesOptions: timeSeriesOptions,
    axisGrid: axisGrid,
    axisTicks: axisTicks
  };
})(window);
