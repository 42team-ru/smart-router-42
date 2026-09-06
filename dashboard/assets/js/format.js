/* Форматтеры и цветовые токены исходов. Ничего про DOM и данные не знает. */
(function (global) {
  'use strict';

  // Линейный конгруэнтный генератор — тот же, что в дизайне: одинаковый seed
  // даёт одинаковый датасет, поэтому демо-выдача воспроизводима между
  // перезагрузками страницы.
  function rnd(seed) {
    var x = seed;
    return function () {
      x = (x * 1103515245 + 12345) & 0x7fffffff;
      return x / 0x7fffffff;
    };
  }

  function fi(n) {
    return Math.round(n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ' ');
  }

  function fm(n) { return fi(n) + ' ₽'; }

  function fmk(n) {
    return n >= 1000000
      ? (n / 1000000).toFixed(1).replace('.', ',') + 'M ₽'
      : fi(n) + ' ₽';
  }

  function hhmm(d) { return d.toTimeString().slice(0, 8); }

  var TONES = {
    approved: { bg: 'var(--posq)', fg: 'var(--pos)' },
    rejected: { bg: 'var(--negq)', fg: 'var(--neg)' },
    expired: { bg: 'var(--warnq)', fg: 'var(--warn)' },
    _default: { bg: 'var(--g200)', fg: 'var(--g700)' }
  };

  function tone(result) { return TONES[result] || TONES._default; }

  // skipped — это не исход операции, а пропуск звена каскада: красить его
  // в нейтральный серый, а не в цвет одноимённого исхода.
  function attemptTone(status) { return tone(status === 'skipped' ? '_none' : status); }

  function esc(value) {
    return String(value == null ? '' : value)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  global.RCFormat = {
    rnd: rnd, fi: fi, fm: fm, fmk: fmk, hhmm: hhmm,
    tone: tone, attemptTone: attemptTone, esc: esc
  };
})(window);
