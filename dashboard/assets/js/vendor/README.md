# vendor/

Third-party libraries, vendored locally so the console works without a live
CDN connection.

- `chart.umd.min.js` — Chart.js 4.5.1 (MIT), pulled from
  `https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.5.1/chart.umd.min.js`.
  UMD build, chosen so a plain `<script>` tag defines `window.Chart` with no
  bundler.
