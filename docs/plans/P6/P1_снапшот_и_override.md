# П1 — наш снапшот провайдеров и override из конфига

## Зачем

ТЗ (`reference/TZ.md`, таблица «Поля, которые командам полезно добавить самим») прямо
предлагает завести `volume_share_pct`, `requests_per_minute_limit`, `daily_turnover_min`,
`daily_turnover_max`. В снапшоте организаторов их нет, поэтому сегодня:

- стратегия `obligations` (`lib/routing/strategies/obligations.rb`) на боевых данных
  вырождается в сортировку по имени — 3 балла техжюри написаны и мертвы;
- `bin/route` каждый запуск печатает предупреждение «правило не применяется»;
- цель по объёму в отчёте подменяется `traffic_percentage`
  (`lib/reporting/distributions.rb:62`), поэтому пример ТЗ «vipay 50% оборота,
  остальные 50%» нигде не задан.

Этот пакет добавляет три поля из четырёх. Четвёртое (`requests_per_minute_limit`)
делает П2 — отдельно, потому что оно единственное влияет на допуск.

## Решение, которое кодируется (принято человеком, развилка Ф-3)

Файл организаторов `reference/data/providers.json` **не трогаем**. Наш снапшот —
новый файл `data/providers.json`: побайтовая копия снапшота организаторов плюс
добавленные поля. Валидатор продолжает считать допуск по пристинному файлу, поэтому
зелёный `make validate` доказывает: наши решения допустимы по снапшоту организаторов.

Источник правды по свойствам провайдера — снапшот. Ключи `obligations` и `rate_limits`
в `config/routing.yml` сохраняются и получают явную семантику **override поверх
снапшота**: контракт конфига не ломается, ключи перестают быть мёртвыми.

## Файлы

- `data/providers.json` — новый.
- `lib/io/provider_overrides.rb` — новый.
- `bin/route` — дефолтный `providers_path`, применение override, честный текст
  оставшегося предупреждения.
- `README.md` — §3 (раскладка каталогов), §4 (таблица конфигурации: строки
  `obligations` и `rate_limits` сейчас говорят «на public-снапшоте не применяются» —
  это станет неправдой).

## Значения полей (числа из ТЗ, не выдуманные)

| провайдер | volume_share_pct | daily_turnover_min | daily_turnover_max |
|---|---|---|---|
| vipay | 50 | null | 5000000 |
| payflow | 30 | 2000000 | null |
| quickpay | 20 | null | null |
| spacepayments | 0 | null | null |

`50` — прямо из ТЗ («vipay 50% оборота, остальные 50%»); `30/20` делят остаток
в пропорции паспортных `35:25`. `2 000 000` на payflow и `5 000 000` на vipay — тоже
дословно из ТЗ (строка «не менее 2 000 000 ₽/сутки на payflow; не более 5 000 000 ₽
на vipay»). `requests_per_minute_limit` в этом пакете **не добавляем**.

## Публичный интерфейс

```ruby
module Io
  # Накладывает override из конфига поверх снапшота. Не мутирует вход
  # (Domain::Provider — Data, используем #with), порядок провайдеров сохраняет.
  module ProviderOverrides
    # obligations: {"payflow" => {"daily_turnover_min" => 2_000_000}, ...}
    # rate_limits: {"vipay" => 7, ...}
    # -> Array[Domain::Provider]
    def self.apply(providers, obligations: {}, rate_limits: {})
  end
end
```

Правила:

1. Значение из конфига перекрывает значение из снапшота. Отсутствующий ключ конфига
   оставляет снапшотное значение (в том числе `nil`).
2. `rate_limits[name]` кладётся в `requests_per_minute_limit`.
3. Ключ конфига, которому не соответствует ни один провайдер снапшота, — ошибка
   конфигурации: `raise` с сообщением
   `конфиг: obligations для неизвестного провайдера foo, bar` (имена **отсортированы**,
   иначе текст зависит от порядка ключей YAML). Аналогично для `rate_limits`.
   В `bin/route` это ловится существующим `fail_with` (сообщение + код 1, без трейса).
4. Пустые `obligations`/`rate_limits` — законный вход, возвращается тот же список.

В `bin/route`:

- `default_options[:providers_path]` → `'data/providers.json'`;
- после `load_providers` — `Io::ProviderOverrides.apply(...)` с ключами конфига;
- `warn_unapplied_config` остаётся только для тех полей, которых действительно нет
  ни в снапшоте, ни в override (после этого пакета — только `requests_per_minute_limit`),
  и текст должен быть честным: правило не применяется, потому что поля нет ни в снапшоте,
  ни в `rate_limits`.

## Готово когда

1. `bundle exec bin/route reference/data/operations_queue_10.json 2>&1 | grep -c 'obligations'`
   → `0`. Строка про `rate_limits` до П2 остаётся допустимой и печатается ровно один раз.
2. `diff out/routing_decisions_test.json routing_decisions_test.json` — пусто.
   Решения меняться не должны: активная стратегия `count_share`, добавленные поля
   на допуск не влияют.
3. `ruby -rjson -e 'r=JSON.parse(File.read("out/routing_report_test.json"));
   p r["volume_distribution"].transform_values{|v| v["target_pct"]}'`
   → `{"vipay"=>50, "payflow"=>30, "quickpay"=>20, "spacepayments"=>0}`.
4. `make validate` → `Пройдено: 29`, `Ошибок: 0`, `Предупр.: 0`.
5. `make gate` зелёный, `make determinism` → `детерминизм: OK`.

## Обязательные спеки

- `spec/io/provider_overrides_spec.rb`:
  наложение min/max и rate limit; приоритет конфига над значением снапшота;
  отсутствующий ключ не затирает снапшотное значение; вход не мутирован
  (сравнить исходные объекты до и после); `raise` с отсортированным списком имён
  на неизвестном провайдере; пустой конфиг возвращает эквивалентный список.
- `spec/io/providers_snapshot_parity_spec.rb` (**главный страховочный спек**):
  `data/providers.json` и `reference/data/providers.json` совпадают по **всем** ключам,
  которые читает `eligible_providers` валидатора (status, traffic_percentage,
  limit_amount_min/max, daily_amount_limit, daily_approved_amount,
  in_progress_count_limit/count, in_progress_amount_limit/amount, available_requisites,
  provider_margin_pct, merchant_margin_pct, allow_negative_agreement, banks,
  exclude_banks), состав и порядок `payment_system` совпадают, а множество различий
  ключей равно ровно `{volume_share_pct, daily_turnover_min, daily_turnover_max}`
  (в П2 к нему добавится `requests_per_minute_limit`).
- `spec/routing/strategies/obligations_spec.rb` (дополнить или завести): на снапшоте
  `data/providers.json` payflow, не набравший `daily_turnover_min`, стоит выше vipay,
  а vipay, перешагнувший 90% от `daily_turnover_max`, — ниже. Числа в `explain`.
- `spec/bin/route_spec.rb`: прогон с дефолтными путями не печатает предупреждения
  про `obligations`; прогон с `--providers reference/data/providers.json` печатает
  (старое поведение сохранено).
- `spec/reporting/report_builder_spec.rb`: `volume_distribution.*.target_pct` берётся
  из `volume_share_pct`, а не из `traffic_percentage`.

## Что может сломаться молча

| Риск | Чем ловится |
|---|---|
| `data/providers.json` разъезжается со снапшотом организаторов по hard-полю — наш допуск перестаёт совпадать с валидаторским | `providers_snapshot_parity_spec` |
| override молча игнорирует опечатку в имени провайдера, правило снова мертво | спек на `raise` с отсортированным списком |
| `volume_share_pct` меняет ранжирование `volume_share` и, через него, чьи-то ожидания | п.2 приёмки: decisions побайтово не изменились |
| `apply` мутирует входные объекты, и второй прогон в одном процессе (сравнение из П4) видит уже изменённый снапшот | спек «вход не мутирован» |
| текст предупреждения остаётся общим и в час стопкода снова врёт | п.1 приёмки + спек на `bin/route` |
