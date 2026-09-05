# План: HTTP-сервис поверх smart-router-42 (реализация)

## Контекст

К существующему CLI-ядру добавляется минимальный HTTP-сервис для потоковой
обработки операций одна-за-одной, с живой аналитикой из SQLite. CLI остаётся
главной точкой входа (валидатор организаторов гоняется через него), сервис —
параллельный демонстрационный слой.

Сервис не оценивается баллами (SCOPE §5), но даёт демонстрируемую фичу для
питча: «онлайн-роутинг с параллельным чтением аналитики через API».

## Предпосылки (уже готово)

Контракт и preview-UI зафиксированы в предыдущем коммите и служат источником
правды для реализации:

- **`docs/openapi.yaml`** — OpenAPI 3.0.3, 12 путей / 14 операций, 23 схемы,
  60 `$ref` (все разрешаются). Схемы `Provider`/`Operation`/`Decision`/
  `Attempt`/`Report` совпадают 1-в-1 с существующими JSON в `reference/data/`
  и корне репо.
- **`public/swagger/`** — Swagger UI (swagger-ui-dist 5.32.15) с двойным
  режимом загрузки: `file://` берёт встроенный `openapi-spec.js`, `http://`
  тянет `/openapi.yaml`.
- **`scripts/embed_openapi.rb`** — регенерация `public/swagger/openapi-spec.js`
  из `docs/openapi.yaml`. Запускается через `make openapi-embed`.
- **`Makefile`** — `openapi-check`, `openapi-embed`, `install-swagger-ui`.
- **`README.md` §8** — как открыть preview без сервера.

Реализация ниже **обязана соответствовать `docs/openapi.yaml`**: имена путей,
формы запросов/ответов, коды ошибок, семантика фильтров. Если по ходу
всплывёт несогласуемая деталь — сначала правится openapi.yaml (+ `make
openapi-embed`), потом код.

## Non-goals

- Не заменяем CLI.
- Не трогаем `lib/routing/**`, `lib/execution/**`, `lib/state/**`, `lib/domain/**` —
  ядро остаётся байт-в-байт как есть.
- Не персистим `State::Providers` — оно живёт в памяти процесса и умирает
  вместе с ним, ровно как в CLI (инвариант из CLAUDE.md).
- Не добавляем auth, multi-tenancy, look-ahead.
- Не добавляем real concurrency — single-thread Puma по конструкции.

## Зафиксированные архитектурные решения

| Решение | Выбор | Обоснование |
|---|---|---|
| Модель состояния | Глобальный in-memory `State::Providers` | Один провайдер = один дневной лимит, как в реальности. |
| Concurrency | Puma workers=1 threads=1, без Mutex | Атомарность бесплатно, детерминизм гарантирован конструкцией. Ruby GVL всё равно не даёт параллельности на CPU-bound. |
| Персистентность аналитики | SQLite (WAL) + gem `sqlite3` | Тысячи-десятки тысяч решений в 24ч окне не помещаются в память без деградации GC. |
| Схема БД | Нормализованная: `decisions` + `attempts` | Агрегаты по attempts (skip_reasons, attempt_distribution) считаются одним SQL-запросом. |
| Retention | Конфигурируемый, дефолт 24ч, чистка on-write | Один процесс, нет фоновых потоков. |
| Reset-семантика | `/snapshot`, `/config`, `/reset`, `/bootstrap` — все destructive: чистят state + DB | Смена контекста = сброс аналитики, иначе агрегаты по разным правилам. |
| Framework | Sinatra + Puma | Минимум магии, идеален для 12 эндпоинтов из openapi.yaml. |

## Раскладка файлов

Новое:
```
bin/serve                           # запуск Puma с config.ru
config.ru                           # Rack entrypoint
config/service.yml                  # port, db_path, retention_hours
data/decisions.db                   # runtime, в .gitignore
lib/api/
  app.rb                            # Sinatra::Base приложение (роутинг по openapi.yaml)
  gateway.rb                        # единственная точка доступа к state + repo
  decisions_repo.rb                 # обёртка SQLite (schema, CRUD, retention)
  stream_report_builder.rb          # сборка routing_report из SQL-запросов
  validators.rb                     # ручная валидация входа
  errors.rb                         # классы исключений API-слоя
  serializers.rb                    # domain object -> JSON hash
lib/config/
  service_config.rb                 # загрузка config/service.yml
spec/api/
  app_spec.rb                       # rack-test на все эндпоинты
  gateway_spec.rb                   # изоляция логики gateway
  decisions_repo_spec.rb            # CRUD, retention, агрегаты, :memory: DB
  stream_report_builder_spec.rb     # проверка равенства с ReportBuilder на одном датасете
  validators_spec.rb                # позитив/негатив валидации
scripts/
  compare_batch_vs_cli.sh           # e2e: /operations/batch на очереди == bin/route
```

Изменяемое:
```
Gemfile                            # + sinatra, puma, sqlite3, rack-test (dev)
Gemfile.lock                       # bundle update
.gitignore                         # + data/
Makefile                           # + `make serve`
```

Не трогается:
```
bin/route                          # CLI как есть
lib/routing/**                     # ядро
lib/execution/**                   # ядро
lib/state/**                       # State::Providers без Mutex, без правок
lib/io/**                          # уже поддерживает Hash-вход (Builder), переиспользуем
lib/reporting/**                   # CLI-репортинг, работает с pairs; не пересекается с сервисным
config/routing.yml                 # domain-config, отдельно от service-config
docs/openapi.yaml                  # контракт зафиксирован — правится только при обоснованном расхождении
public/swagger/                    # UI зафиксирован
```

## Единая точка доступа: `Api::Gateway`

Все HTTP-обработчики Sinatra ходят к состоянию **только** через `Api::Gateway`.
Сам gateway держит:
- ссылку на текущий `State::Providers` (или `nil` пока не грузили snapshot);
- ссылку на текущий `Routing::Planner` и `Execution::Executor` (пересобираются
  при snapshot/config/bootstrap);
- ссылку на `Api::DecisionsRepo`;
- текущий `seed` и `Config::RoutingConfig`.

Публичные методы (соответствуют операциям в openapi.yaml):
```ruby
class Api::Gateway
  def load_snapshot(payload)      ; ... ; end   # POST /snapshot     + reset DB
  def apply_config(payload)       ; ... ; end   # POST /config       409 if no snapshot; + reset DB
  def bootstrap(payload)          ; ... ; end   # POST /bootstrap    + reset DB
  def reset                       ; ... ; end   # POST /reset        409 if no snapshot; + reset DB
  def current_snapshot            ; ... ; end   # GET  /snapshot     409 if no snapshot; отдаёт как загружено (без in-memory мутаций)
  def current_config              ; ... ; end   # GET  /config       всегда 200 (дефолт из YAML при старте)
  def route(operation_hash)       ; ... ; end   # POST /operations   planner+executor+repo.insert
  def route_batch(operations)     ; ... ; end   # POST /operations/batch (сахар, seq loop)
  def state_snapshot              ; ... ; end   # GET  /state        актуальные in-memory счётчики
  def report(filter)              ; ... ; end   # GET  /report       StreamReportBuilder
  def list_decisions(filter, limit:, offset:)   # GET  /decisions
  def health                      ; ... ; end   # GET  /health
end
```

**Важно**: `current_snapshot` (GET /snapshot) ≠ `state_snapshot` (GET /state).
Первый отдаёт снапшот **как загружен** (immutable копия из последнего POST),
второй — **текущие мутируемые счётчики** `State::Providers`. Обе ручки нужны:
клиент часто хочет знать «что было изначально» + «что сейчас».

Зачем gateway (даже в single-thread): (1) обработчики Sinatra не знают о
конкретных классах ядра; (2) тестируется отдельно от Rack-слоя; (3) при
возможном будущем апгрейде до multi-thread (RWLock) — локи ставятся в одном
месте.

## Схема БД

```sql
CREATE TABLE decisions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  operation_id      TEXT    NOT NULL,
  created_at        INTEGER NOT NULL,      -- unix epoch, передаётся из Ruby
  merchant_id       TEXT    NOT NULL,      -- из snapshot.merchant на момент решения
  gate              TEXT    NOT NULL,      -- из snapshot.gateway на момент решения
  amount            INTEGER NOT NULL,
  bank              TEXT,
  selected_provider TEXT,                  -- NULL если fallback провалился
  simulated_result  TEXT    NOT NULL,      -- approved/rejected/expired/no_provider
  latency_sec       INTEGER,
  strategy          TEXT
);
CREATE INDEX idx_dec_created  ON decisions(created_at);
CREATE INDEX idx_dec_provider ON decisions(selected_provider);
CREATE INDEX idx_dec_merchant ON decisions(merchant_id);
CREATE INDEX idx_dec_gate     ON decisions(gate);

CREATE TABLE attempts (
  decision_id INTEGER NOT NULL REFERENCES decisions(id) ON DELETE CASCADE,
  attempt_no  INTEGER NOT NULL,
  provider    TEXT    NOT NULL,
  decision    TEXT    NOT NULL,             -- selected/skipped
  reason      TEXT    NOT NULL,
  details     TEXT    NOT NULL,
  result      TEXT,                          -- approved/rejected/expired, NULL для skipped
  PRIMARY KEY (decision_id, attempt_no)
);
CREATE INDEX idx_att_reason ON attempts(reason);

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;
```

Все запросы `SELECT ... ORDER BY id ASC` (или `created_at, id`) — гарантия
детерминизма вывода.

**Retention**: после каждого `INSERT INTO decisions` выполняется
`DELETE FROM decisions WHERE created_at < ?` с параметром `now -
retention_seconds`. `ON DELETE CASCADE` уносит attempts.

## Ключевые методы ядра, которые сервис переиспользует

- `Routing::Planner#plan(operation, state)` — `lib/routing/planner.rb:29`
- `Execution::Executor#run(plan, operation, state)` — `lib/execution/executor.rb:23`
- `Io::QueueLoader::Builder#call` — `lib/io/queue_loader.rb:47` (принимает Hash)
- `Io::ProvidersLoader.build_provider(raw)` — `lib/io/providers_loader.rb`
- `Config::Loader.load(path)` — `lib/config/loader.rb:21`
- `State::Providers.new(providers)` — `lib/state/providers.rb:38`
- `Reporting::ReportBuilder.build(pairs, ...)` — `lib/reporting/report_builder.rb:28`
  используется как reference для тестов `StreamReportBuilder`

## Валидация входа

`Api::Validators` — простой модуль с чистыми функциями:
```ruby
Validators.operation(hash)   -> [:ok, op_hash] | [:error, [{field, code}...]]
Validators.snapshot(payload) -> [:ok, ...]     | [:error, ...]
Validators.config(hash)      -> [:ok, ...]     | [:error, ...]
Validators.bootstrap(payload)-> [:ok, ...]     | [:error, ...]
Validators.report_filter(qs) -> [:ok, filter]  | [:error, ...]
```

Требуемые поля операции берём из `Io::QueueLoader::Builder#process`
(`lib/io/queue_loader.rb:60-74`): `operation_id, created_at, amount, bank,
payout_requisite`, `amount > 0`. Не дублируем логику — вызываем `Builder` и
мапим ошибки в API-формат ошибок, зафиксированный в `openapi.yaml#/components/schemas/Error`.

## Конфигурация

Новый `config/service.yml`:
```yaml
service:
  port: 4567
  db_path: "./data/decisions.db"
  retention_hours: 24
  swagger_path: "./public/swagger"
  openapi_path: "./docs/openapi.yaml"
```

Загрузка — `Config::ServiceConfig.load(path)`, Data-объект. При старте сервера
`bin/serve` читает и передаёт в `Api::App`.

Не трогаем `config/routing.yml` — это domain-config (strategy, targets),
отдельно от operational settings.

## Тесты

- `spec/api/decisions_repo_spec.rb` — SQLite `:memory:`, `before(:each)`
  пересоздаёт схему. CRUD, retention (передаём фиксированный `now`), агрегаты.
- `spec/api/stream_report_builder_spec.rb` — прогоняем один и тот же датасет
  через `Reporting::ReportBuilder` (CLI) и `Api::StreamReportBuilder` (SQL) и
  сверяем результат deep-equal. Гарантия семантической эквивалентности.
- `spec/api/gateway_spec.rb` — интеграция planner+executor+repo, без Rack.
- `spec/api/app_spec.rb` — `Rack::Test`, все эндпоинты, happy path + error
  codes. Сверка формы ответов со схемами из `docs/openapi.yaml`.
- `spec/api/validators_spec.rb` — таблицы позитивных/негативных кейсов.

Существующие `spec/routing/**`, `spec/execution/**`, `spec/state/**` — не трогаются.

## Порядок реализации

1. **`config/service.yml` + `lib/config/service_config.rb`** — конфиг.
2. **`lib/api/decisions_repo.rb` + spec** — схема, insert, retention, list, aggregates.
3. **`lib/api/stream_report_builder.rb` + spec** — сверка с `ReportBuilder`.
4. **`lib/api/validators.rb` + `lib/api/errors.rb` + specs**.
5. **`lib/api/gateway.rb` + spec** — единая точка доступа.
6. **`lib/api/serializers.rb`** — domain → hash для ответов (форма из `openapi.yaml`).
7. **`lib/api/app.rb`** — Sinatra-роуты по путям из `openapi.yaml`, тонкая обёртка над gateway.
8. **`config.ru` + `bin/serve`** — Rack + Puma.
9. **`spec/api/app_spec.rb`** — интеграционные тесты через `Rack::Test`, сверка
   форм ответов со схемами `openapi.yaml`.
10. **`scripts/compare_batch_vs_cli.sh`** — e2e-скрипт, гоняет очередь через
    `/operations/batch` и сравнивает с выходом `bin/route`.
11. **README-обновление** — как поднять сервис (`make serve`), curl-примеры,
    ссылка на живой `/swagger`.

## Верификация (end-to-end)

```bash
# 1. Тесты
make gate                                # rspec + rubocop, зелёные

# 2. CLI не сломан
make validate                            # валидатор организаторов, 0 ошибок

# 3. Сервис поднимается
make serve &                             # bin/serve → Puma :4567

# 4. Swagger UI открывается (спека уже в public/swagger/openapi-spec.js)
curl -sf http://localhost:4567/swagger/ | grep -q swagger-ui

# 5. Bootstrap + одна операция + отчёт
curl -sf -X POST http://localhost:4567/bootstrap \
  -H 'Content-Type: application/json' \
  -d @scripts/fixtures/bootstrap.json
curl -sf -X POST http://localhost:4567/operations \
  -H 'Content-Type: application/json' \
  -d '{"operation": {"operation_id":"op_106", ...}}'
curl -sf http://localhost:4567/report | jq

# 6. Batch-режим воспроизводит CLI
scripts/compare_batch_vs_cli.sh          # батчует queue через API, сверяет с bin/route diff-free
```

Финальная проверка: `scripts/compare_batch_vs_cli.sh` — гарантия что сервис на
том же входе даёт байт-в-байт тот же выход, что CLI. Это защита детерминизма и
валидность инвариантов CLAUDE.md.
