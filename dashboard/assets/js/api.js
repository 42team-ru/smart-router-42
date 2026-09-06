/* HTTP-клиент консоли. Единственное место, которое знает про сеть.
 *
 * База по умолчанию — тот же origin, откуда отдана страница (bin/serve
 * раздаёт и консоль, и API). Для отладки против чужого сервиса:
 * /console/?api=http://localhost:4567
 */
(function (global) {
  'use strict';

  var base = (function () {
    var m = /[?&]api=([^&]+)/.exec(global.location.search);
    return m ? decodeURIComponent(m[1]).replace(/\/+$/, '') : '';
  })();

  // Ошибки API имеют стабильную форму {error, message} — тащим их в UI как
  // есть, чтобы 409 no_snapshot можно было отличить от «сервис не отвечает».
  function ApiError(status, code, message, details) {
    this.name = 'ApiError';
    this.status = status;
    this.code = code || 'transport_error';
    this.message = message || 'сервис недоступен';
    this.details = details || null;
  }
  ApiError.prototype = Object.create(Error.prototype);

  function query(params) {
    var parts = [];
    Object.keys(params || {}).forEach(function (k) {
      var v = params[k];
      if (v === null || v === undefined || v === '') return;
      parts.push(encodeURIComponent(k) + '=' + encodeURIComponent(v));
    });
    return parts.length ? '?' + parts.join('&') : '';
  }

  function request(method, path, options) {
    var opts = options || {};
    var init = { method: method, headers: { Accept: 'application/json' } };
    if (opts.body !== undefined) {
      init.headers['Content-Type'] = 'application/json';
      init.body = JSON.stringify(opts.body);
    }

    return fetch(base + path + query(opts.params), init).then(function (res) {
      return res.text().then(function (text) {
        var payload = null;
        try { payload = text ? JSON.parse(text) : null; } catch (e) { payload = null; }

        if (res.ok) return payload;
        if (payload && payload.error) {
          throw new ApiError(res.status, payload.error, payload.message, payload.details);
        }
        throw new ApiError(res.status, 'http_' + res.status, text || res.statusText);
      });
    }, function (e) {
      throw new ApiError(0, 'transport_error', 'сервис не отвечает: ' + e.message);
    });
  }

  global.RCApi = {
    base: base,
    ApiError: ApiError,

    health: function () { return request('GET', '/health'); },
    capabilities: function () { return request('GET', '/capabilities'); },
    snapshot: function () { return request('GET', '/snapshot'); },
    config: function () { return request('GET', '/config'); },
    state: function () { return request('GET', '/state'); },
    report: function (filter) { return request('GET', '/report', { params: filter }); },

    overview: function (filter, buckets) {
      var params = Object.assign({ buckets: buckets }, filter);
      return request('GET', '/analytics/overview', { params: params });
    },
    decisions: function (filter, limit, offset) {
      var params = Object.assign({ limit: limit, offset: offset }, filter);
      return request('GET', '/analytics/decisions', { params: params });
    },

    route: function (operation) {
      return request('POST', '/operations', { body: { operation: operation } });
    },
    routeBatch: function (operations) {
      return request('POST', '/operations/batch', { body: { operations: operations } });
    },
    applyConfig: function (config) {
      return request('POST', '/config', { body: { config: config } });
    },
    bootstrap: function (snapshot, config) {
      return request('POST', '/bootstrap', { body: { snapshot: snapshot, config: config } });
    },
    reset: function () { return request('POST', '/reset'); }
  };
})(window);
