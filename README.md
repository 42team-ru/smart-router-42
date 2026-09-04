# smart-routing-42 — движок умного роутинга выплат

## 1. Что это

Офлайн-движок маршрутизации выплат. На входе — снапшот провайдеров
(`reference/data/providers.json`) и очередь заявок
(`reference/data/operations_queue_10.json`). На выходе — два файла в корне
репозитория:

- `routing_decisions_test.json` — по одному решению на операцию: выбранный
  провайдер, каскад попыток, причина каждого отсева;
- `routing_report_test.json` — агрегаты прогона.

Чистый Ruby 3.3: `lib/` + `bin/route` + RSpec. Без Rails, без БД, без очередей и
без сети. **Нейросетей в коде нет** — прямой запрет ТЗ. Все решения
алгоритмические и объяснимые: каждое поле `details` содержит конкретное
сравнение с числами.

Прогон детерминирован: два запуска на одном входе дают побайтово одинаковый
выход (`make determinism`). В решающем пути (`lib/routing`, `lib/execution`) нет
`rand`, `shuffle`, `sample` и `Time.now` — это проверяется статически
(`make no-random`).

## 2. Как запустить

| Команда | Что делает | Что печатает при успехе |
|---|---|---|
| `make install` | `bundle install` | установленные гемы |
| `make route` | прогон на `reference/data/operations_queue_10.json`, выход в `out/` | `Прочитано операций: 10`, два пути `Записано:` |
| `make deliver` | тот же прогон, но выход в **корень репозитория** (боевые имена файлов) | те же две строки `Записано:` |
| `make gate` | ворота: `rspec` + `rubocop` + проверка отсутствия случайности | `0 failures`, `no offenses detected`, `детерминизм: источников случайности нет` |
| `make validate` | прогон плюс валидатор организаторов `reference/scripts/validate_10.rb` | `✅ Пройдено: 29`, `❌ Ошибок:   0`, `⚠️  Предупр.: 0` |
| `make determinism` | два прогона подряд и побайтовый `diff` | `детерминизм: OK` |

Напрямую:

```
bundle exec bin/route <queue.json> [--out-dir DIR] [--providers PATH]
                      [--config PATH] [--strategy NAME]
                      [--outcomes deterministic|always_ok] [--seed SEED]
```

По умолчанию `--out-dir out`. Корневые `routing_decisions_test.json` и
`routing_report_test.json` обновляет `make deliver`.

## 3. Раскладка каталогов

| Путь | Что внутри |
|---|---|
| `bin/route` | CLI, единственная точка входа и композиционный корень |
| `config/routing.yml` | вся настройка поведения |
| `lib/io/` | загрузка и валидация входных данных |
| `lib/routing/` | допуск (hard-constraints), стратегии, слои, план маршрута |
| `lib/execution/` | проход по каскаду, исходы, состояние резервов |
| `lib/state/` | счётчики провайдеров, наблюдаемая статистика |
| `lib/reporting/` | оба выходных файла |
| `spec/` | RSpec |
| `docs/` | проектные документы, `docs/examples/` — образцы для расширения |
| `reference/` | данные и валидатор организаторов |
| `scripts/` | вспомогательные скрипты (детерминизм, демо расширяемости) |

## 4. Конфигурация

Текущий `config/routing.yml` (комментарии опущены):

```yaml
strategy: count_share
layers: []

allocator:
  tie_break: [weight_desc, name_asc]

outcomes:
  source: deterministic
  seed: 42
  calibrate_from_history: true

amount_ranges:
  - { from: 500, to: 50000, prefer: payflow }
  - { from: 50001, to: 100000, prefer: vipay }
  - { from: 100001, to: null, prefer: quickpay }

obligations:
  payflow: { daily_turnover_min: 2000000 }
  vipay: { daily_turnover_max: 5000000 }

rate_limits:
  vipay: 7
  quickpay: 15

fallback_provider: spacepayments
```

Файл читает `bin/route` на старте, ровно один раз, и передаёт объектом
`Config::RoutingConfig` в `Routing::Assembly`. Ни `Planner`, ни стратегии, ни
`Executor` файловой системы не касаются.

Схему всех восьми ключей валидирует `Config::Loader` (`lib/config/loader.rb`);
битый конфиг даёт сообщение и код выхода 1, а не трейс. Валидность схемы и
влияние на поведение — разные вещи, поэтому таблица ниже честно разделяет их.

| Ключ | Что делает | Влияет сегодня |
|---|---|---|
| `strategy` | активная стратегия ранжирования каскада | **да** |
| `layers` | слои-модификаторы поверх стратегии | нет: реестр `Routing::Layers` пуст. `layers: []` — штатно; любой непустой список роняет запуск с кодом 1. Слои приезжают в Ф4 (X-1, X-2) |
| `amount_ranges` | полосы суммы для стратегии `amount_range` | **да**, когда `strategy: amount_range` |
| `fallback_provider` | провайдер последней надежды (fallback по допуску) | **да**: имя уходит в `Routing::Planner` |
| `allocator.tie_break` | описывает порядок разрешения ничьих | нет: отдельно не читается. Стратегии разрешают ничьи по весу, затем по имени — это записано в их коде, а не берётся из YAML |
| `outcomes.source`, `outcomes.seed` | источник симулированных исходов и seed | нет: значения продублированы дефолтами CLI (`--outcomes deterministic --seed 42`) и совпадают с ними. Управляются флагами |
| `outcomes.calibrate_from_history` | калибровка конверсий по `operations_history.csv` | нет: `Strategies::Conversion` калибруется по истории всегда, ключ не читается |
| `obligations` | целевые дневные обороты провайдеров | нет: полей `daily_turnover_min` / `daily_turnover_max` нет в `reference/data/providers.json`, загрузчик даёт `nil`. Схема валидируется, поведение не подключено |
| `rate_limits` | ограничение интенсивности (запросов в минуту) | нет: поля `requests_per_minute_limit` нет в `providers.json`, `Constraints::RateLimit` на реальном снапшоте — no-op |

Следствие для `obligations`: стратегия `obligations` на публичном снапшоте
вырождается — у всех провайдеров `min`/`max` равны `nil`, и порядок
определяется именем. Это известное ограничение данных, а не скрытая логика.

## 5. Приоритет источников

```
--strategy NAME   (CLI)   сильнее
strategy:         (YAML)
```

Кода-дефолта стратегии нет: имя всегда приходит либо из флага, либо из конфига,
и в сообщении об ошибке источник называется явно. Путь к самому конфигу меняется
флагом `--config` (по умолчанию `config/routing.yml`).

```
# стратегия из конфига
bundle exec bin/route reference/data/operations_queue_10.json --out-dir out

# конфиг из другого файла, стратегия перекрыта флагом
bundle exec bin/route reference/data/operations_queue_10.json \
  --config /tmp/routing.yml --strategy priority --out-dir out
```

## 6. Демо: одна строка YAML меняет распределение

Меняется единственная строка `strategy:` в `config/routing.yml`, код не тронут:

```
sed 's/^strategy: count_share$/strategy: load/' config/routing.yml >/tmp/load.yml
bundle exec bin/route reference/data/operations_queue_10.json --out-dir out
bundle exec bin/route reference/data/operations_queue_10.json --config /tmp/load.yml --out-dir out
```

| Строка в конфиге | payflow | quickpay | vipay |
|---|---|---|---|
| `strategy: count_share` (как в репозитории) | 3 | 4 | 3 |
| `strategy: load` | 2 | 8 | 0 |

Числа измерены на `reference/data/operations_queue_10.json` с дефолтами
`bin/route` (`--outcomes deterministic --seed 42`). Валидатор организаторов на
обоих прогонах остаётся зелёным: `❌ Ошибок:   0`. Автоматически это проверяет
`spec/bin/config_switch_spec.rb`.

Полный набор стратегий на той же очереди (все семь — `✅ 29 / ❌ 0`):

| `strategy` | payflow | quickpay | vipay |
|---|---|---|---|
| `amount_range` | 4 | 3 | 3 |
| `conversion` | 2 | 4 | 4 |
| `count_share` | 3 | 4 | 3 |
| `load` | 2 | 8 | 0 |
| `obligations` | 4 | 6 | 0 |
| `priority` | 3 | 3 | 4 |
| `volume_share` | 3 | 3 | 4 |

## 7. Как добавить стратегию — три шага, без правок ядра

1. **Создать файл** `lib/routing/strategies/<name>.rb`. Имя файла обязано
   совпадать с именем стратегии. Наследник `Routing::Strategies::Base`, три
   метода и регистрация внизу файла:

   ```ruby
   require_relative '../strategies'

   module Routing
     module Strategies
       class MyRule < Base
         def rank(candidates, operation, state) = candidates.sort_by(&:name)
         def name = 'my_rule'
         def explain(ranked, operation, state) = "my_rule: #{ranked.first.name} priority=1"
       end

       register('my_rule', MyRule)
     end
   end
   ```

   Нужны данные из конфига — объявить фабрику
   `def self.from_config(config) = new(...)`: `Strategies.build` вызовет её,
   если конфиг передан. Готовый образец на 40 строк —
   `docs/examples/reverse_priority.rb`.

2. **Написать `strategy: <name>`** в `config/routing.yml`.

3. **Запустить `make validate`.**

Править не нужно ничего больше: `bin/route` загружает каталог стратегий целиком
(`Routing::Strategies.load_all!`, `Dir[...].sort` — порядок регистрации
детерминирован), реестр про конкретные классы не знает, `Planner` не знает имён
стратегий вообще.

Ограничения, которые обязана соблюдать стратегия:

- `rank` возвращает **перестановку** допущенных кандидатов — не добавляет и не
  удаляет провайдеров; `Planner` это проверяет и падает при нарушении;
- обработка **онлайновая**: заглядывать в будущие операции очереди нельзя;
- никаких `rand`, `shuffle`, `sample`, `Time.now`; ничьи разрешаются
  детерминированно (например, по имени);
- дроби сравниваются перекрёстным умножением целых, без приведения к float;
  веса — в базисных пунктах;
- `explain` возвращает строку с конкретными числами: причина без числа не
  принимается.

Живая демонстрация на минуту — `bash scripts/demo_new_strategy.sh`: копирует
`docs/examples/reverse_priority.rb` в `lib/routing/strategies/`, показывает
реестр 7 → 8, гоняет `bin/route` с конфигом, где заменена одна строка, печатает
распределение и вердикт валидатора, убирает копию и показывает реестр обратно 7.
Скрипт временно пишет в `lib/`, поэтому в `make gate` он не входит и
запускается руками; копия удаляется при любом исходе, включая Ctrl+C.

## 8. Что мы сознательно не делаем

- **Нейросети, ML, предсказание успеха** — прямой запрет ТЗ, дисквалификация.
- **Rails, БД, очереди, Sidekiq, Redis** — вход и выход это файлы, веб-слой
  баллов не даёт.
- **Единый «smart score» из десяти слагаемых** — необъяснимо, а объяснимость
  решений оценивается отдельно.

Полный список — `docs/SCOPE.md` §5.
