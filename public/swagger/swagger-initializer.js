window.onload = function() {
  // Спеку берём в трёх режимах приоритета:
  //   1. ?spec=<url>                      — явный оверрайд из query-string
  //   2. window.OPENAPI_SPEC              — встроенный объект из openapi-spec.js
  //      (нужен для file://, потому что Chrome блокирует XHR к соседним файлам)
  //   3. /openapi.yaml                    — фетчим у Sinatra при http://
  var params   = new URLSearchParams(window.location.search);
  var override = params.get('spec');
  var isFile   = window.location.protocol === 'file:';

  var config = {
    dom_id: '#swagger-ui',
    deepLinking: true,
    presets: [
      SwaggerUIBundle.presets.apis,
      SwaggerUIStandalonePreset
    ],
    plugins: [
      SwaggerUIBundle.plugins.DownloadUrl
    ],
    layout: "StandaloneLayout",
    tryItOutEnabled: true,
    persistAuthorization: false
  };

  if (override) {
    config.url = override;
  } else if (window.OPENAPI_SPEC) {
    config.spec = window.OPENAPI_SPEC;
  } else if (!isFile) {
    config.url = '/openapi.yaml';
  } else {
    document.getElementById('swagger-ui').innerHTML =
      '<div style="padding:2em;font-family:sans-serif">' +
      '<h2>Swagger UI: спека не найдена</h2>' +
      '<p>Файл <code>public/swagger/openapi-spec.js</code> отсутствует.</p>' +
      '<p>Собери его: <code>make openapi-embed</code> или <code>ruby scripts/embed_openapi.rb</code>.</p>' +
      '</div>';
    return;
  }

  window.ui = SwaggerUIBundle(config);
};
