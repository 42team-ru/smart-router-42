# Ф0 — Контракты. План фазы

Источники: `docs/SCOPE.md` → `docs/ARCHITECTURE.md` → `docs/TASKS.md` → `docs/OWNERSHIP.md`,
`AGENTS.md`, `reference/scripts/validate_10.rb`, `reference/data/*`, `reference/TZ.md`.

**Цель фазы (гейт из TASKS.md):** Максим и Кирилл могут работать, не заглядывая в код Вовы.
Операционально это значит: в `main` лежат подключаемые заглушки семи интерфейсов, три
JSON-фикстуры форматов, зелёный `make gate`, работающий `bin/route` и CI, который валит
билд на источнике недетерминизма.

---

## 0. Фактическое состояние репозитория (проверено, не по памяти)

- Ruby-кода **нет вообще**: ни `lib/`, ни `spec/`, ни `bin/`, ни `Gemfile`, ни `Rakefile`,
  ни `.rubocop.yml`, ни `config/`. Есть только `docs/`, `reference/`, `scripts/` (обвязка
  агентов), `Makefile`, `.github/workflows/tests.yml`, `.gitignore`, пустая папка `out/`.
- `Makefile` уже ожидает `bundle exec rspec`, `bundle exec rubocop`, `bundle exec bin/route`
  и `OUT ?= out/routing_decisions.json`.
- `.github/workflows/tests.yml` уже содержит `make gate`, `make validate`, `make determinism`
  и инлайновый греп на `rand|shuffle|sample|Time.now`. Ruby в CI прибит к `3.3`.
- Локальный интерпретатор — **ruby 4.0.6**, bundler 4.0.16.
- Данные организаторов лежат в `reference/data/`, папки `data/` в репозитории **нет**
  (TASKS.md и OWNERSHIP.md пишут `data/...` — это устаревший путь, читать как `reference/data/...`).
- `.gitignore` игнорирует `/out/`.
- Проверено запуском: файл решений, где всем десяти операциям назначен `spacepayments`,
  даёт у валидатора ровно `✅ Пройдено: 12 / ❌ Ошибок: 4 / ⚠️ Предупр.: 13`, exit 1.
  Четыре ошибки — это ровно четыре эталонных кейса (op_103, op_104, op_107, op_108).
  Это **опорное число фазы Ф0**, см. пакет P4 и §7.

---

## 1. Противоречия в постановке (не решены молча)

### C-A. `OUT=out/routing_decisions.json` против требования организаторов

`Makefile` пишет вывод в `out/routing_decisions.json`, а `.gitignore` эту папку игнорирует.
ТЗ (`reference/TZ.md`, раздел «Ожидаемый минимальный результат») и `SCOPE.md` §0 требуют
файлы **`routing_decisions_test.json` и `routing_report_test.json` в корне репозитория,
ветка `main`**, имена сверяются посимвольно. `OWNERSHIP.md` §7 отдельно предупреждает:
«не `_final`, не в `out/`, не в другой ветке». То есть отрепетированная командой команда
кладёт файлы туда, куда организаторы смотреть не будут.

Два варианта:

| | Вариант A: всегда в корень | Вариант C (рекомендуемый): каталог параметром, имена всегда боевые |
|---|---|---|
| Поведение | `bin/route <queue>` пишет `./routing_decisions_test.json` и `./routing_report_test.json` | `bin/route <queue> [--out-dir DIR]`, `DIR` по умолчанию `out/`; имена файлов **всегда** `routing_decisions_test.json` / `routing_report_test.json` |
| Makefile | `OUT ?= routing_decisions_test.json` | `OUT ?= out/routing_decisions_test.json`, плюс цель `deliver: bundle exec bin/route $(QUEUE) --out-dir .` |
| Плюс | одна команда, ноль расхождений между репетицией и часом стопкода | рабочие прогоны не пачкают корень и git-diff; час стопкода — одна отрепетированная цель `make deliver` |
| Минус | каждый прогон на public-очереди перезаписывает артефакт, который обязан содержать результат по test-очереди; риск закоммитить публичный результат | в час стопкода команда отличается от повседневной — снимается тем, что обе репетиции (гейт Ф2 и заморозка) делаются через `make deliver` |
| Общее для обоих | имя файла **никогда** не конструируется из имени входной очереди и не содержит `_final`, `out`, дат | |

**По умолчанию в план заложен вариант C.** Если человек выбирает A — это правка одной
строки в `Makefile` и одного дефолта в `bin/route`, пакет P4 переделывается за 10 минут.
Оба варианта одинаково удовлетворяют `make validate`, потому что `OUT` подставляется в
валидатор явно.

### C-B. `make validate` осмысленен только на public-очереди

`reference/scripts/validate_10.rb` строкой 18–19 жёстко берёт `DATA_DIR = ../data` от
своего расположения и `QUEUE_FILENAME = 'operations_queue_10.json'`. Он **всегда** сверяет
файл решений с `reference/data/operations_queue_10.json`, чем бы мы ни кормили `bin/route`.
Значит `make validate QUEUE=<любая другая очередь>` даст ложное «отсутствуют решения для…».
Фиксируем как правило: **`make validate` запускается только на public-очереди**, для
test-очереди валидатор будет свой, «схожий скрипт» от организаторов. В `Makefile` цель
`validate` жёстко прибивается к `reference/data/operations_queue_10.json`, а не к `$(QUEUE)`.

### C-C. Ruby 3.3 в CI против Ruby 4.0.6 локально

`ruby/setup-ruby@v1` с `ruby-version: '3.3'`, локально 4.0.6. Если `Gemfile` получит
директиву `ruby "3.3.x"` — сломается локальная разработка; если `.rubocop.yml` получит
`TargetRubyVersion: 4.0` — CI на 3.3 может ругаться на синтаксис. Решение: **в `Gemfile`
директивы `ruby` нет вообще**, в `.rubocop.yml` `TargetRubyVersion: 3.3`, код пишется на
подмножестве 3.3. `Gemfile.lock` коммитится (`bundler-cache: true` в CI его использует).

### C-D. «`bin/route` пишет пустой валидный JSON» (C-5) — две трактовки

Буквально «пустой» — это `[]`, и тогда валидатор даст 10 ошибок покрытия. Но та же строка
TASKS.md требует «читает очередь», а гейт Ф0 требует, чтобы Кирилл мог работать против
готового пайплайна. Трактуем как **«структурно валидный файл с решением на каждую операцию
очереди, без содержательного роутинга»**: `selected_provider = spacepayments`, один attempt.
Обоснование: покрытие очереди и структура закрываются уже на Ф0, остаётся ровно 4 ошибки на
эталонных кейсах — это измеримая база, от которой Ф1 обязана прийти к нулю. Вариант `[]`
такой базы не даёт и не проверяет чтение очереди.

### C-E. Инвариант «spacepayments — fallback по допуску» и заглушка P4

Формально заглушка не нарушает инвариант: допуск на Ф0 не реализован, ни один внешний
провайдер его не прошёл (проходить нечего). Но это единственное место фазы, где заглушка
внешне похожа на боевое поведение. Помечается `TODO(Ф1/R-11)` в коде и вынесено в §7 рисков.

### C-F. `make validate` в CI будет красным всю Ф0

Шаг `- run: make validate` в `.github/workflows/tests.yml` завершится с exit 1 (4 ошибки).
На Ф0 это ожидаемо. Пакет P4 помечает шаг `continue-on-error: true` с комментарием,
называющим точное ожидаемое число ошибок и фазу снятия. **Снятие пометки — часть гейта Ф1,
в Ф0 не входит.** Альтернативу «ослабить критерий валидатора» не рассматриваем.

### C-G. Поля, которых нет в `providers.json`

`requests_per_minute_limit`, `volume_share_pct`, `daily_turnover_min/max` в снапшоте
отсутствуют — ТЗ прямо разрешает завести их самим. На Ф0 это только строки в фикстуре
конфига-заглушки и комментарий в интерфейсе; сами проверки — Ф1/Ф3. Инвариант, который
фиксируем уже сейчас: **ограничение, параметра которого нет, не отсеивает никого**
(как `null` в лимитах у spacepayments).

---

## 2. Что именно замораживается: семь интерфейсов

Список ровно из `docs/OWNERSHIP.md` §2, он же `ARCHITECTURE.md` §5–8. Ниже — файл,
публичная сигнатура и то, что метод обязан гарантировать.

| # | Интерфейс | Файл | Сигнатура |
|---|---|---|---|
| 1 | Constraint | `lib/routing/constraints/base.rb` | `.violation(provider, operation, state) -> nil \| Routing::Violation` |
| 2 | Strategy | `lib/routing/strategies/base.rb` | `#rank(candidates, operation, state) -> Array<Provider>` |
| 3 | Layer | `lib/routing/layers/base.rb` | `#adjust(ranked, operation, state) -> Array<Provider>` |
| 4 | RoutePlan | `lib/routing/route_plan.rb` | `.new(operation:, candidates:, skipped:)` |
| 5 | Executor | `lib/execution/executor.rb` | `#run(plan, operation, state) -> Execution::Outcome` |
| 6 | State::Providers | `lib/state/providers.rb` | `#reserve(provider, operation)`, `#commit(...)`, `#rollback(...)`, `#hold(...)` |
| 7 | OutcomeSource | `lib/execution/outcome_source/base.rb` | `#call(operation, provider, attempt_no) -> :approved \| :rejected \| :expired` |

Вспомогательные типы, без которых сигнатуры не читаются (замораживаются вместе с ними,
но логики не несут — только чтение атрибутов):

| Тип | Файл | Содержимое |
|---|---|---|
| `Routing::Violation` | `lib/routing/violation.rb` | `Data.define(:reason, :details)`, `#to_attempt` |
| `Routing::Attempt` | `lib/routing/attempt.rb` | элемент `attempts`, `#to_h` с фиксированным порядком ключей |
| `Execution::Outcome` | `lib/execution/outcome.rb` | `Data.define(:selected, :attempts, :result)` |
| `Domain::Operation` | `lib/domain/operation.rb` | `operation_id`, `created_at`, `amount` (Integer), `bank`, `card_brand`, `payout_requisite` |
| `Domain::Provider` | `lib/domain/provider.rb` | все поля из `providers.json` + доступ к «нашим» полям из §C-G |
| `Routing::Reasons` | `lib/routing/reasons.rb` | `SKIP` (10 дословных причин), `SELECTED` (5 причин выбора) |

---

## 3. Три формата данных (C-2): точное содержимое фикстур

Все три лежат в `spec/fixtures/contracts/`. Это **эталон формата, а не результат прогона**.
Против них пишут Максим и Кирилл; менять их можно только через Вову.

### 3.1 `spec/fixtures/contracts/attempt.json`

Массив из четырёх канонических элементов `attempts` — по одному на каждый разрешённый вид
записи. Ключи в каждом элементе идут именно в этом порядке.

```json
[
  {
    "provider": "payflow",
    "decision": "skipped",
    "reason": "amount_exceeds_limit",
    "details": "52000 > limit_amount_max 50000"
  },
  {
    "provider": "vipay",
    "decision": "selected",
    "reason": "best_target_adherence",
    "details": "недобор доли 6.7 п.п. против перебора quickpay 4.2 п.п.",
    "strategy": "count_share",
    "attempt_no": 1,
    "result": "rejected"
  },
  {
    "provider": "quickpay",
    "decision": "selected",
    "reason": "next_in_cascade",
    "details": "vipay отказал на попытке 1, следующий в каскаде по count_share",
    "strategy": "count_share",
    "attempt_no": 2,
    "result": "approved"
  },
  {
    "provider": "spacepayments",
    "decision": "selected",
    "reason": "fallback_no_eligible_provider",
    "details": "допустимых внешних провайдеров 0 из 3",
    "strategy": "fallback",
    "attempt_no": 1,
    "result": "approved"
  }
]
```

Что здесь зафиксировано и почему:

- `decision` принимает **только** `selected` и `skipped` (валидатор, строки 65–67).
  Неудачная попытка — это `selected` + `result: "rejected"`, а не третье значение `decision`.
- `provider`, `decision`, `reason` обязательны всегда (валидатор, строки 61–64).
- `details` обязателен по правилу команды и **содержит хотя бы одну цифру**.
- `strategy`, `attempt_no`, `result` — наши поля, ТЗ разрешает добавлять; присутствуют
  только у `selected`.
- `reason` у `skipped` берётся строго из `Routing::Reasons::SKIP`.

### 3.2 `spec/fixtures/contracts/decisions.json`

Массив из двух решений: вырожденный (единственный допустимый) и каскадный (отказ → следующий).
Оба взяты с реальных операций public-очереди, чтобы фикстуру можно было сверять с
`reference_decisions.json`.

```json
[
  {
    "operation_id": "op_103",
    "selected_provider": "quickpay",
    "attempts": [
      {"provider": "vipay", "decision": "skipped", "reason": "amount_exceeds_limit",
       "details": "150000 > limit_amount_max 100000"},
      {"provider": "payflow", "decision": "skipped", "reason": "amount_exceeds_limit",
       "details": "150000 > limit_amount_max 50000"},
      {"provider": "quickpay", "decision": "selected", "reason": "only_eligible_provider",
       "details": "1 допустимый провайдер из 3", "strategy": "count_share",
       "attempt_no": 1, "result": "approved"}
    ],
    "simulated_result": "approved",
    "latency_sec": 29
  },
  {
    "operation_id": "op_106",
    "selected_provider": "quickpay",
    "attempts": [
      {"provider": "payflow", "decision": "skipped", "reason": "amount_exceeds_limit",
       "details": "52000 > limit_amount_max 50000"},
      {"provider": "vipay", "decision": "selected", "reason": "best_target_adherence",
       "details": "недобор доли 6.7 п.п. против перебора quickpay 4.2 п.п.",
       "strategy": "count_share", "attempt_no": 1, "result": "rejected"},
      {"provider": "quickpay", "decision": "selected", "reason": "next_in_cascade",
       "details": "vipay отказал на попытке 1, следующий в каскаде по count_share",
       "strategy": "count_share", "attempt_no": 2, "result": "approved"}
    ],
    "simulated_result": "approved",
    "latency_sec": 29
  }
]
```

Инварианты формата, которые эта фикстура фиксирует:

- порядок ключей верхнего уровня: `operation_id`, `selected_provider`, `attempts`,
  `simulated_result`, `latency_sec`;
- один провайдер встречается в `attempts` не более одного раза (`ARCHITECTURE.md` §15);
- `selected_provider` совпадает с `provider` последнего `selected`-элемента, у которого
  `result != "rejected"`;
- `selected_provider` входит в `reference_decisions.json → eligible_providers[operation_id]`;
- у op_103 — совпадает с `deterministic_cases` (`quickpay`);
- порядок элементов = порядок рассмотрения.

### 3.3 `spec/fixtures/contracts/report.json`

Полный набор ключей, включая те, что наполняются только на Ф2/Ф5. Заводятся сразу
(`TASKS.md`, «Правила ведения»: формат после Ф2 не меняется). Числа — из
`ARCHITECTURE.md` §12 и §10, то есть это ещё и целевой ориентир.

```json
{
  "period": "2026-07-30",
  "total_operations": 10,
  "strategy": "count_share",
  "distribution": {
    "vipay":    {"count": 4, "share_pct": 40.0, "target_pct": 40, "achievable_pct": 40.0, "deviation_pp": 0.0},
    "payflow":  {"count": 3, "share_pct": 30.0, "target_pct": 35, "achievable_pct": 30.0, "deviation_pp": 0.0},
    "quickpay": {"count": 3, "share_pct": 30.0, "target_pct": 25, "achievable_pct": 30.0, "deviation_pp": 0.0},
    "spacepayments": {"count": 0, "share_pct": 0.0, "target_pct": 0, "achievable_pct": 0.0, "deviation_pp": 0.0}
  },
  "volume_distribution": {
    "vipay":    {"amount": 132000, "share_pct": 34.2, "target_pct": 50, "achievable_pct": 34.2, "deviation_pp": 0.0},
    "payflow":  {"amount": 63800,  "share_pct": 16.5, "target_pct": 25, "achievable_pct": 16.5, "deviation_pp": 0.0},
    "quickpay": {"amount": 190000, "share_pct": 49.3, "target_pct": 25, "achievable_pct": 49.3, "deviation_pp": 0.0},
    "spacepayments": {"amount": 0, "share_pct": 0.0, "target_pct": 0, "achievable_pct": 0.0, "deviation_pp": 0.0}
  },
  "attempt_distribution": {
    "vipay": {"attempts": 5, "successful": 4, "observed_conversion": 0.8},
    "payflow": {"attempts": 3, "successful": 3, "observed_conversion": 1.0},
    "quickpay": {"attempts": 3, "successful": 3, "observed_conversion": 1.0},
    "spacepayments": {"attempts": 0, "successful": 0, "observed_conversion": null}
  },
  "skip_reasons": {"amount_exceeds_limit": 3, "bank_not_in_list": 5, "amount_below_minimum": 2},
  "projected_daily_utilization": {
    "vipay":    {"used": 3332000, "limit": 5000000, "utilization_pct": 66.6},
    "payflow":  {"used": 2963800, "limit": 3000000, "utilization_pct": 98.8},
    "quickpay": {"used": 1290000, "limit": 8000000, "utilization_pct": 16.1},
    "spacepayments": {"used": 0, "limit": null, "utilization_pct": null}
  },
  "fallback": {
    "first_attempt_success": 9,
    "recovered_by_fallback": 1,
    "fallback_rate_pct": 10.0,
    "spacepayments_used": 0,
    "cascade_exhausted": 0
  },
  "benchmark": {"offline_optimum_deviation_pp": null, "ours_deviation_pp": null, "competitive_ratio": null},
  "deviation_causes": [
    "quickpay +5 п.п. к цели: op_103, op_104, op_108 не имели альтернатив по сумме и банку"
  ],
  "recommendations": [
    "payflow: conversion_24h заявлена 0.91, наблюдаемая 0.474 по 100 операциям истории — пересчитать по факту",
    "payflow: свободно 100 000 ₽ при среднем чеке 38 580 ₽ — снизить traffic_percentage 35 → 20 до сброса дневного лимита"
  ]
}
```

Обязательные по ТЗ ключи: `period`, `total_operations`, `distribution`, `skip_reasons`,
`projected_daily_utilization`, `recommendations` — их отсутствие означает «файл не приложен».
Порядок ключей верхнего уровня фиксирован ровно так, как выше.
`null` в `benchmark` и в лимитах spacepayments легален и означает «значения нет».

---

## 4. Пакеты работ

| ID | Пакет | TASKS | Зависит | Проверяется одной командой |
|---|---|---|---|---|
| P0 | Скелет: Gemfile, Rakefile, RSpec, RuboCop, smoke-спек | C-3 | — | `make gate` |
| P1 | Семь интерфейсов + вспомогательные типы + словарь причин | C-1 | P0 | `make gate` |
| P2 | Три JSON-фикстуры контрактов + спеки на них | C-2 | P1 | `make gate` |
| P3 | Проверка на недетерминизм: скрипт + цель Makefile + CI | C-4 | P1 | одна составная команда, см. бриф |
| P4 | `bin/route`: чтение очереди, запись двух файлов | C-5 | P0 | `make route` + `make validate` |
| P5 | Гейт фазы: сквозной прогон всех проверок | — | P0–P4 | `make gate && make route && make no-random && make determinism` |

Граф и параллельность:

```
P0 ──┬── P1 ──┬── P2
     │        └── P3
     └── P4
              всё сходится в P5
```

После P0 пакеты P1 и P4 идут параллельно (разные файлы, разные владельцы: P1 — зона Вовы,
P4 — зона Кирилла, P0/P3 — зона Максима). P2 и P3 параллельны между собой.

---

## 5. Брифы кодеру

Каждый бриф самодостаточен. Кодер плана не видел.

---

### БРИФ P0 — скелет репозитория (C-3)

**Контекст.** Репозиторий `smart-routing-42` — офлайн-движок роутинга выплат на чистом
Ruby. Кода нет вообще, ты создаёшь скелет с нуля. Rails, БД, очередей, веб-сервера в
проекте нет и не будет. Нейросети и ML-библиотеки запрещены правилами хакатона.
`Makefile` и `.github/workflows/tests.yml` уже существуют и ожидают `bundle exec rspec`,
`bundle exec rubocop`, `bundle exec bin/route`.

**Создать:**

1. `Gemfile` — `source "https://rubygems.org"`. Гемы: `rspec` (~> 3.13), `rubocop`
   (~> 1.60), `rubocop-rspec`, `rake`. **Директиву `ruby "..."` не добавлять** —
   локально Ruby 4.0.6, в CI 3.3, любой пин ломает одну из сторон.
2. `Gemfile.lock` — результат `bundle install`, коммитится.
3. `Rakefile` — задачи `spec` (RSpec::Core::RakeTask), `rubocop` (RuboCop::RakeTask),
   `default = [:spec, :rubocop]`. Никаких других задач в этом пакете
   (`rake validate` — отдельная задача Ф1, не трогай).
4. `.rspec` — `--require spec_helper`, `--format documentation`, `--color`.
5. `spec/spec_helper.rb` — `RSpec.configure`: `expect` синтаксис, `disable_monkey_patching!`,
   `config.order = :defined` (**не** `:random` — порядок спеков должен быть воспроизводим),
   `$LOAD_PATH.unshift` на `lib/`, константа `SPEC_ROOT` и хелпер
   `fixture_path(*parts)` → `File.join(__dir__, "fixtures", *parts)`,
   хелпер `reference_path(*parts)` → путь внутрь `reference/data`.
6. `.rubocop.yml` — `TargetRubyVersion: 3.3`; `require: rubocop-rspec`;
   `AllCops.NewCops: enable`; `Exclude`: `reference/**/*`, `vendor/**/*`, `out/**/*`,
   `scripts/**/*`; `Metrics/BlockLength` исключить для `spec/**/*`;
   `Style/Documentation` — `Enabled: false`; `Layout/LineLength` — `Max: 100`.
   Файл `bin/route` должен попадать под инспекцию (`AllCops.Include` дополнить `bin/*`).
7. `spec/smoke_spec.rb` — минимум **два** реальных примера, чтобы зелёный `rspec` не был
   зелёным из-за нуля примеров:
   - `RUBY_VERSION` >= "3.3";
   - `reference/data/operations_queue_10.json` парсится и содержит ровно 10 операций,
     первая — `op_101`.

**Инварианты.** Никакой бизнес-логики в этом пакете. Ничего в `lib/` не создаём.

**Критерий приёмки (одна команда):**

```
make gate
```

Успех: `bundle exec rspec` печатает `2 examples, 0 failures` (или больше примеров,
0 failures), `bundle exec rubocop` печатает `no offenses detected` и **инспектирует
не ноль файлов**. Ненулевой exit — FAIL.

---

### БРИФ P1 — семь интерфейсов и словарь причин (C-1)

**Контекст.** Движок роутинга выплат, чистый Ruby, файлы на вход и выход. Сейчас
замораживаются публичные контракты, чтобы двое других разработчиков писали код
параллельно, не заглядывая в реализацию. **В этом пакете пишутся только заглушки:
сигнатуры, документирующие комментарии, `raise NotImplementedError`. Никакой рабочей
логики — она приходит в следующей фазе.**

**Жёсткие запреты для всего, что лежит в `lib/routing/` и `lib/execution/`:**
слова `rand`, `shuffle`, `sample`, `Time.now` не должны встречаться **даже в комментариях
и в именах** — CI валит билд по грепу на них. Пиши «жребий», «перестановка», «пример»,
«текущий момент».

Все файлы начинаются с `# frozen_string_literal: true`.

**Создать (13 файлов):**

`lib/domain/operation.rb`
```ruby
module Domain
  # Одна заявка из очереди. Только чтение, без логики.
  # amount — целое число рублей: вся решающая арифметика целочисленная.
  Operation = Data.define(:operation_id, :created_at, :amount, :bank,
                          :card_brand, :payout_requisite)
end
```

`lib/domain/provider.rb` — `Data.define` со всеми полями `providers.json`:
`payment_system, status, traffic_percentage, priority, limit_amount_min, limit_amount_max,
daily_amount_limit, daily_approved_amount, in_progress_count_limit, in_progress_count,
in_progress_amount_limit, in_progress_amount, available_requisites, conversion_24h,
avg_latency_sec, banks, exclude_banks, provider_margin_pct, merchant_margin_pct,
allow_negative_agreement` плюс поля, которых нет в снапшоте и которые мы заводим сами
(ТЗ разрешает): `volume_share_pct, requests_per_minute_limit, daily_turnover_min,
daily_turnover_max`. Комментарий над классом обязан содержать правило:
**`nil` в любом лимите означает «ограничения нет», а не ноль** — так устроен spacepayments.
Метод `#name` — алиас `payment_system`.

`lib/routing/reasons.rb`
```ruby
module Routing
  module Reasons
    # Причины отсева. Дословно из reference/data/reference_decisions.json,
    # валидатор организаторов сверяет их посимвольно. Свои формулировки запрещены.
    SKIP = %w[
      provider_inactive
      zero_traffic_share
      amount_below_minimum
      amount_exceeds_limit
      daily_limit_exceeded
      in_progress_limit_exceeded
      bank_not_in_list
      negative_margin
      no_requisites
      rate_limit_exceeded
    ].freeze

    # Причины выбора. Первые две — из sample_routing_decisions.json организаторов.
    SELECTED = %w[
      only_eligible_provider
      first_eligible
      best_target_adherence
      next_in_cascade
      fallback_no_eligible_provider
    ].freeze
  end
end
```

`lib/routing/violation.rb`
```ruby
module Routing
  # Результат сработавшей hard-проверки.
  # reason  — строка из Reasons::SKIP, дословно.
  # details — человекочитаемое сравнение, ОБЯЗАНО содержать число:
  #           "52000 > limit_amount_max 50000". Причина без числа не принимается.
  Violation = Data.define(:reason, :details) do
    def to_attempt(provider) = ... # -> Routing::Attempt с decision: "skipped"
  end
end
```

`lib/routing/attempt.rb` — элемент массива `attempts`.
Поля: `provider, decision, reason, details, strategy, attempt_no, result`.
`decision` принимает **только** `"selected"` и `"skipped"` — валидатор организаторов
считает любое другое значение ошибкой структуры. Неудачная попытка кодируется как
`decision: "selected"` + `result: "rejected"`, а не третьим значением `decision`.
Метод `#to_h` возвращает хеш с **фиксированным порядком ключей**
`provider, decision, reason, details, strategy, attempt_no, result`, при этом `nil`-поля
выбрасываются, а `provider`, `decision`, `reason` присутствуют всегда.
Конструктор валидирует `decision` и, если он не из списка, кидает `ArgumentError`.

`lib/routing/constraints/base.rb`
```ruby
module Routing
  module Constraints
    # Hard-constraint: отвечает на вопрос «можно ли вообще», а не «кого предпочесть».
    # Одна проверка — один файл — одна причина.
    # Возвращает nil, если провайдер проходит, иначе Routing::Violation.
    # nil в поле лимита = ограничения нет = проверка не срабатывает.
    class Base
      def self.violation(provider, operation, state)
        raise NotImplementedError, "#{name}.violation"
      end
    end
  end
end
```

`lib/routing/constraints.rb` — модуль `Routing::Constraints` с `REASONS = Reasons::SKIP`.
**`REGISTRY` в этом пакете не заводить**: пустой реестр молча пропустил бы всех.
Вместо него — комментарий `# REGISTRY появляется в задаче R-10` с перечнем девяти
классов в фиксированном порядке: `Status, TrafficShare, AmountRange, DailyLimit,
InProgress, BankFilter, Margin, Requisites, RateLimit`.

`lib/routing/strategies/base.rb`
```ruby
module Routing
  module Strategies
    # Стратегия УПОРЯДОЧИВАЕТ допущенных, а не выбирает одного:
    # первый элемент — выбор, весь список — каскад.
    # Контракт: возвращает перестановку candidates. Не добавляет, не удаляет,
    # не обращается к будущим операциям очереди (обработка онлайновая).
    # Сравнение дробей — перекрёстным умножением целых, без float.
    class Base
      def rank(candidates, operation, state)
        raise NotImplementedError, "#{self.class}#rank"
      end
    end
  end
end
```

`lib/routing/layers/base.rb` — то же для `#adjust(ranked, operation, state)`.
Комментарий обязан содержать инвариант: **слой не может вернуть в список того, кого отсёк
допуск; он только переставляет.** Возвращает перестановку `ranked` того же размера.

`lib/routing/route_plan.rb`
```ruby
module Routing
  # План маршрута одной операции: упорядоченный каскад и отсеянные с причинами.
  # Строится ДО первой попытки и после отказа не пересчитывается.
  #   candidates — Array<Domain::Provider>, порядок = порядок каскада, без дублей
  #   skipped    — Array<[Domain::Provider, Routing::Violation]>
  class RoutePlan
    def initialize(operation:, candidates:, skipped:) = ...
    attr_reader :operation, :candidates, :skipped
    def attempt_no_for(provider) = ... # 1-based позиция в каскаде
    def empty? = ...                   # ни одного допущенного -> fallback по допуску
  end
end
```
Конструктор валидирует: в `candidates` нет дублей по имени, пересечение `candidates` и
`skipped` пусто. Нарушение — `ArgumentError`.

`lib/execution/outcome.rb`
```ruby
module Execution
  # Итог прохода по каскаду.
  #   selected — Domain::Provider, попавший в selected_provider
  #   attempts — Array<Routing::Attempt> в порядке рассмотрения
  #   result   — :approved | :rejected | :expired
  Outcome = Data.define(:selected, :attempts, :result)
end
```

`lib/execution/executor.rb`
```ruby
module Execution
  # Проход по каскаду. Исполнитель не знает про доли, стратегия не знает про таймауты.
  #   approved -> commit, каскад закончен
  #   rejected -> rollback, следующий кандидат
  #   expired  -> hold, каскад НЕ продолжается (результат условно успешен)
  # Каскад исчерпан -> selected_provider последний реальный кандидат,
  # НЕ spacepayments: spacepayments — fallback по допуску, а не по исходу.
  class Executor
    def run(plan, operation, state)
      raise NotImplementedError, "#{self.class}#run"
    end
  end
end
```

`lib/execution/outcome_source/base.rb`
```ruby
module Execution
  module OutcomeSource
    # Источник исхода попытки. Чистая функция, детерминированная по своим аргументам:
    # два прогона одного входа обязаны дать побайтово одинаковый вывод.
    # Реализации: Deterministic (хеш от seed), Scripted (сценарий из YAML),
    # AlwaysOk / AlwaysFail (вырожденные случаи).
    class Base
      def call(operation, provider, attempt_no)
        raise NotImplementedError, "#{self.class}#call"
      end
    end
  end
end
```

`lib/state/providers.rb`
```ruby
module State
  # Счётчики провайдеров. Резерв, а не пост-фактум:
  # счётчики закрепляются за провайдером в момент попадания в каскад.
  #
  #   исход      in_progress     daily_approved   счётчик доли
  #   approved   освобождается   + amount         остаётся у провайдера
  #   rejected   освобождается   не трогаем       возвращается
  #   expired    держится        не трогаем       остаётся
  #
  # Незакрытый резерв тихо ломает eligibility на седьмой заявке.
  class Providers
    def reserve(provider, operation)  = raise NotImplementedError
    def commit(provider, operation)   = raise NotImplementedError
    def rollback(provider, operation) = raise NotImplementedError
    def hold(provider, operation)     = raise NotImplementedError
  end
end
```

**Спек, который надо написать:** `spec/contracts/interfaces_spec.rb`.
Он ловит переименование метода и молчаливую смену сигнатуры. Для каждого из семи
интерфейсов проверяет:

1. класс/модуль определён и файл подключается по `require` от `lib/`;
2. метод существует (`respond_to?` для классовых, `instance_method` для инстансных);
3. **имена и порядок параметров** совпадают дословно —
   `described_class.instance_method(:rank).parameters == [%i[req candidates], %i[req operation], %i[req state]]`;
   для `RoutePlan#initialize` — `[%i[keyreq operation], %i[keyreq candidates], %i[keyreq skipped]]`;
4. вызов заглушки поднимает `NotImplementedError`;
5. `Routing::Reasons::SKIP` содержит ровно 10 элементов, заморожен (`frozen?`), и
   **множество причин из `reference/data/reference_decisions.json → skip_reasons_expected`
   является его подмножеством** (файл читается спеком, не копируется);
6. `Routing::Attempt.new(decision: "failed", ...)` поднимает `ArgumentError`, а
   `"selected"` и `"skipped"` — нет;
7. `Routing::Attempt#to_h.keys` для полного набора полей равен
   `%i[provider decision reason details strategy attempt_no result]` (порядок важен),
   а для минимального — `%i[provider decision reason]`;
8. `Routing::RoutePlan.new` с дублем в `candidates` поднимает `ArgumentError`.

**Критерий приёмки (одна команда):**

```
make gate
```

Успех: 0 failures, `no offenses detected`, число примеров выросло относительно P0.
FAIL при любом ненулевом exit.

---

### БРИФ P2 — три фикстуры форматов (C-2)

**Контекст.** Движок роутинга выплат. Замораживаются три формата данных, против которых
двое других разработчиков пишут код, не заглядывая в реализацию: элемент `attempts`,
`routing_decisions.json`, `routing_report.json`. Фикстуры — эталон формата, не результат
прогона. Уже существуют: `lib/routing/reasons.rb` с `Routing::Reasons::SKIP` и `SELECTED`,
`lib/routing/attempt.rb`, `spec/spec_helper.rb` с хелперами `fixture_path` и `reference_path`.

**Создать три файла с точно этим содержимым** (взять из `docs/plans/PHASE_0.md` §3.1–3.3,
скопировать дословно, включая русский текст в `details` и `recommendations`):

- `spec/fixtures/contracts/attempt.json`
- `spec/fixtures/contracts/decisions.json`
- `spec/fixtures/contracts/report.json`

Файлы в UTF-8, кириллица **не** экранируется в `\uXXXX`, каждый заканчивается переводом
строки. Порядок ключей внутри объектов менять нельзя.

**Создать спек** `spec/contracts/fixtures_spec.rb`. Он повторяет внутри нашего сьюта
проверки валидатора организаторов — так расхождение находится на своём прогоне, а не за час
до стопкода. Логика `validate_structure` дублируется из `reference/scripts/validate_10.rb`,
строки 53–71, **осознанно**: сам скрипт подключить нельзя, он выполняет `main` при загрузке.
Над дублем — комментарий со ссылкой на эти строки.

Проверки для `attempt.json`:
1. массив, 4 элемента;
2. у каждого есть `provider`, `decision`, `reason` (это ровно то, что требует валидатор);
3. `decision` ∈ `["selected", "skipped"]` — никаких `"failed"`, `"rejected"`, `"error"`;
4. у каждого есть непустой `details`, и `details =~ /\d/` — правило «причина без числа
   не принимается»;
5. у `skipped` `reason` ∈ `Routing::Reasons::SKIP`; у `selected` — ∈ `Routing::Reasons::SELECTED`;
6. поля `strategy`, `attempt_no`, `result` есть только у `selected`;
7. `result` ∈ `["approved", "rejected", "expired"]`;
8. каждый элемент конструируется через `Routing::Attempt` без исключения, и его `#to_h`
   после `JSON.parse(JSON.generate(...))` равен исходному элементу фикстуры —
   это связывает фикстуру с кодом, а не оставляет её отдельным документом.

Проверки для `decisions.json`:
1. массив; у каждого решения есть `operation_id`, `selected_provider`, `attempts`;
2. каждый элемент `attempts` проходит те же проверки, что и в `attempt.json`;
3. в пределах одного решения провайдер встречается в `attempts` не более одного раза;
4. `selected_provider` равен `provider` последнего `selected`-элемента, у которого
   `result` не равен `"rejected"`;
5. `selected_provider` входит в
   `reference/data/reference_decisions.json → eligible_providers[operation_id]`
   (файл читается спеком);
6. для `operation_id`, присутствующих в `deterministic_cases`, `selected_provider` равен
   `required_provider` — то есть у op_103 это `quickpay`;
7. `simulated_result` ∈ `["approved", "rejected", "expired"]`, `latency_sec` — Integer > 0.

Проверки для `report.json`:
1. присутствуют **обязательные по ТЗ** ключи: `period`, `total_operations`, `distribution`,
   `skip_reasons`, `projected_daily_utilization`, `recommendations` — их отсутствие
   означает «файл не приложен»;
2. `keys` верхнего уровня идут ровно в порядке из фикстуры (сравнение массивов);
3. каждый элемент `distribution` имеет ровно ключи
   `%w[count share_pct target_pct achievable_pct deviation_pp]`;
4. сумма `count` по `distribution` равна `total_operations`;
5. сумма `share_pct` равна 100.0 (с допуском 0.05);
6. все ключи `skip_reasons` ∈ `Routing::Reasons::SKIP`;
7. ключи `benchmark` и `deviation_causes` присутствуют, `benchmark` допускает `null`
   в значениях — они наполняются позже, но формат заморожен сейчас;
8. `recommendations` — массив строк, каждая содержит цифру (рекомендация без числа —
   это наблюдение, а не рекомендация).

**Инварианты.** Свои формулировки `reason` не изобретать. `details` без числа не
принимается. Ничего в `lib/` в этом пакете не меняем.

**Критерий приёмки (одна команда):**

```
make gate
```

Успех: 0 failures, `no offenses detected`.

---

### БРИФ P3 — защита от недетерминизма (C-4)

**Контекст.** Движок роутинга обязан давать побайтово одинаковый вывод на двух прогонах
одного входа: невоспроизводимые цифры на защите обесценивают результат. Поэтому в
`lib/routing/` и `lib/execution/` запрещены `rand`, `shuffle`, `sample`, `Time.now`.
Сейчас эта проверка живёт инлайном в `.github/workflows/tests.yml` и локально
недоступна. Надо вынести её в скрипт, вызвать из `Makefile` и из CI.

**Дыра, которую надо закрыть.** Текущий инлайновый вариант:
```
if grep -rnE '\b(rand|shuffle|sample)\b|Time\.now' lib/routing lib/execution 2>/dev/null; then
```
Если каталоги переименуют или удалят, `grep` вернёт код 2, `2>/dev/null` съест ошибку,
условие окажется ложным и **проверка молча начнёт всегда проходить**. Новый скрипт обязан
падать, когда проверяемого каталога нет.

**Создать `scripts/check_determinism.sh`:**

- `#!/usr/bin/env bash`, `set -euo pipefail`;
- список каталогов: `lib/routing lib/execution`;
- для каждого: если каталога нет — печать `отсутствует каталог <dir>` и `exit 2`;
- поиск `grep -rnE '\b(rand|shuffle|sample)\b|Time\.now' "$dir"`;
- найдено — печать всех совпадений с именами файлов и номерами строк, затем `exit 1`;
- ничего не найдено ни в одном каталоге — печать `детерминизм: источников случайности нет`
  и `exit 0`;
- `--` перед путями, чтобы имена файлов не превращались в опции.

**Изменить `Makefile`:**

- добавить цель `no-random: ` → `@bash scripts/check_determinism.sh`;
- добавить `no-random` в `.PHONY` и в `help`;
- **включить её в `gate`**: `gate: test lint no-random` — тогда локальный гейт ловит
  проблему без похода в CI.

**Изменить `.github/workflows/tests.yml`:** шаг `no randomness in decision path` заменить
на `- run: make no-random`, инлайновый `if grep ...` удалить.

**Инварианты.** Скрипт не должен зависеть от `bundle`, Ruby и порядка обхода файловой
системы. Никакого содержательного кода в `lib/` этот пакет не добавляет.

**Критерий приёмки (одна составная команда, выполнять целиком):**

```
make no-random && echo "OK-1" && \
printf '# frozen_string_literal: true\nX = [1, 2].sample\n' > lib/routing/tmp_probe.rb && \
( make no-random ; echo "EXIT=$?" ) && rm -f lib/routing/tmp_probe.rb && make no-random && echo "OK-2"
```

Успех — все три условия сразу:
- первая строка вывода содержит `OK-1`;
- в середине видно `lib/routing/tmp_probe.rb:2` и `EXIT=1` (билд падает на добавленном
  источнике случайности);
- в конце видно `OK-2`, файл-зонд удалён (`git status` чистый).

Дополнительно должно быть зелёным: `make gate`.

---

### БРИФ P4 — `bin/route`: чтение очереди и запись двух файлов (C-5)

**Контекст.** Офлайн-движок роутинга выплат, чистый Ruby, единственная точка входа —
`bin/route`. Организаторы за час до стопкода выдадут очередь операций; наш пайплайн должен
превратить её в два JSON-файла с посимвольно точными именами. Сейчас нужен **сквозной
каркас пайплайна без содержательного роутинга**: прочитать очередь, записать структурно
валидные файлы, показать сводку. Настоящий выбор провайдера, hard-constraints и стратегии
приходят следующей фазой — их сейчас писать не надо.

**Создать `bin/route`** (исполняемый, `chmod +x`, shebang `#!/usr/bin/env ruby`,
`# frozen_string_literal: true`):

- аргументы: `bin/route <queue.json> [--out-dir DIR]`, `DIR` по умолчанию `out`;
  разбор — `OptionParser` из stdlib;
- нет аргумента очереди, файл не существует, битый JSON — сообщение на STDERR и `exit 1`;
  ни в одном случае не Ruby-трейс;
- каталог вывода создаётся, если его нет;
- **имена файлов всегда** `routing_decisions_test.json` и `routing_report_test.json`,
  из имени входной очереди они не конструируются никогда;
- для каждой операции очереди пишется одно решение, порядок решений = порядок очереди;
- в конце — сводка на STDOUT: сколько операций прочитано, куда записаны оба файла.

**Что пишется в `routing_decisions_test.json` на этом шаге** (заглушка, помечается в коде
комментарием `# TODO(Ф1/R-11): заменить на настоящий RoutePlan + Executor`):

```json
{
  "operation_id": "<из очереди>",
  "selected_provider": "spacepayments",
  "attempts": [
    {"provider": "spacepayments", "decision": "selected",
     "reason": "fallback_no_eligible_provider",
     "details": "допустимых внешних провайдеров 0 из 3"}
  ],
  "simulated_result": "approved",
  "latency_sec": 15
}
```

`decision` принимает только `"selected"` и `"skipped"` — любое другое значение валидатор
организаторов считает ошибкой структуры.

**Что пишется в `routing_report_test.json`:** структура из
`spec/fixtures/contracts/report.json` — **тот же набор и тот же порядок ключей верхнего
уровня**, но с нулевыми значениями, кроме `period` (дата из `created_at` первой операции,
формат `YYYY-MM-DD`), `total_operations` (реальное число) и `distribution.spacepayments`
(`count` = число операций, `share_pct` = 100.0). Массивы `deviation_causes` и
`recommendations` — пустые. Если фикстура ещё не создана — сверяйся с
`docs/plans/PHASE_0.md` §3.3.

**Правила записи файлов (иначе `make determinism` будет мигать):**

- `File.write(path, JSON.pretty_generate(data) + "\n")`;
- кириллица не экранируется в `\uXXXX`;
- порядок ключей задаётся явно в коде, не наследуется от порядка обхода входных данных;
- никаких `Time.now`, `rand`, `shuffle`, `sample` — ни в коде, ни в комментариях
  (CI валит билд по грепу на эти слова).

**Изменить `Makefile`:**

- `OUT ?= out/routing_decisions_test.json`;
- цель `validate` перестаёт зависеть от `$(QUEUE)`: валидатор организаторов жёстко читает
  `reference/data/operations_queue_10.json` (строки 18–19 скрипта) и на любой другой
  очереди даст ложные ошибки покрытия. Цель становится:
  ```
  validate:
  	bundle exec bin/route reference/data/operations_queue_10.json
  	ruby reference/scripts/validate_10.rb $(OUT)
  ```
- добавить цель `deliver` — единственная команда часа стопкода:
  ```
  deliver:
  	bundle exec bin/route $(QUEUE) --out-dir .
  ```
  и внести `deliver` в `.PHONY` и в `help`.

**Изменить `.github/workflows/tests.yml`:** шагу `- run: make validate` добавить
`continue-on-error: true` и комментарий:
```yaml
# Ф0: заглушка роутинга даёт ровно 4 ошибки на эталонных кейсах
# (op_103, op_104, op_107, op_108). Пометка снимается гейтом Ф1, где ошибок 0.
```

**Спек** `spec/bin/route_spec.rb` — прогоняет CLI как отдельный процесс во временный
каталог (`Dir.mktmpdir`), корень репозитория не трогает:

1. `bin/route reference/data/operations_queue_10.json --out-dir <tmp>` завершается с
   кодом 0;
2. в `<tmp>` появились оба файла с точными именами;
3. в файле решений 10 элементов, множество `operation_id` совпадает с очередью,
   порядок совпадает с порядком очереди;
4. каждый элемент имеет `operation_id`, `selected_provider`, `attempts`; у каждого
   `attempt` есть `provider`, `decision`, `reason`, и `decision` ∈ `%w[selected skipped]`;
5. отчёт содержит обязательные по ТЗ ключи `period`, `total_operations`, `distribution`,
   `skip_reasons`, `projected_daily_utilization`, `recommendations`;
   `total_operations == 10`, `period == "2026-07-30"`;
6. **воспроизводимость:** два прогона в два разных каталога дают побайтово одинаковые
   файлы (`File.binread(a) == File.binread(b)`) для обоих файлов;
7. запуск без аргументов даёт ненулевой код и сообщение на STDERR;
8. запуск на несуществующем файле даёт ненулевой код и сообщение, а не трейс.

**Критерий приёмки (две команды, обе обязательны):**

```
make gate
make validate ; echo "EXIT=$?"
```

Успех:
- `make gate` — 0 failures, `no offenses detected`;
- вывод `make validate` содержит **дословно** строки
  `✅ Все заявки из очереди покрыты`,
  `✅ Структура JSON корректна`,
  и итог ровно `✅ Пройдено: 12`, `❌ Ошибок:   4`, `⚠️  Предупр.: 13`, `EXIT=1`;
- все четыре ошибки — это op_103, op_104, op_107, op_108, то есть эталонные кейсы,
  и ни одной ошибки вида «НЕ допустим» или «ошибки структуры».

Любое другое число ошибок — FAIL. Число 4 — не «пока сойдёт», а точная контрольная
цифра фазы: она означает, что структура и покрытие уже закрыты, а не закрыт только
содержательный выбор провайдера.

---

## 6. Гейт фазы Ф0

Выполняется раннером целиком, после PASS всех пяти пакетов:

```
make gate && \
make no-random && \
make route && \
make determinism && \
( make validate ; echo "VALIDATE_EXIT=$?" ) && \
test -f spec/fixtures/contracts/attempt.json && \
test -f spec/fixtures/contracts/decisions.json && \
test -f spec/fixtures/contracts/report.json && \
git status --porcelain
```

Признаки успеха:

1. `make gate` — `0 failures`, `no offenses detected`;
2. `make no-random` — `детерминизм: источников случайности нет`;
3. `make determinism` — `детерминизм: OK`;
4. `make validate` — `✅ Пройдено: 12`, `❌ Ошибок:   4`, `⚠️  Предупр.: 13`,
   `VALIDATE_EXIT=1`, и все четыре ошибки — эталонные кейсы;
5. три фикстуры на месте;
6. `git status --porcelain` не показывает мусора в корне: нет
   `routing_decisions_test.json` и `routing_report_test.json` в корне репозитория
   (на Ф0 боевые артефакты не коммитятся), нет `lib/routing/tmp_probe.rb`;
7. содержательный признак гейта из TASKS.md: `grep -rn "NotImplementedError" lib | wc -l`
   ≥ 7 — семь интерфейсов существуют как заглушки, значит Максим и Кирилл могут писать
   против них, не заглядывая в реализацию.

Долг, который фаза оставляет сознательно и который снимается гейтом Ф1:
`continue-on-error: true` на шаге `make validate` в CI и заглушка роутинга в `bin/route`.

---

## 7. Что может сломаться молча

| # | Что | Почему молча | Чем ловится |
|---|---|---|---|
| 1 | Греп на недетерминизм всегда проходит, потому что каталог переименован | `grep` по несуществующему пути возвращает 2, `2>/dev/null` съедает ошибку, `if` даёт false | P3: скрипт `exit 2` при отсутствии каталога + негативный тест с файлом-зондом в критерии приёмки |
| 2 | `rspec` зелёный, потому что примеров ноль; `rubocop` зелёный, потому что файлов ноль | ненулевой код возврата не появляется | P0: два реальных примера в `smoke_spec.rb`, требование «инспектировано не ноль файлов» в критерии |
| 3 | Фикстура формата разошлась с валидатором организаторов | валидатор запускается только на прогоне, а фикстуры живут отдельно | P2: `fixtures_spec.rb` дублирует `validate_structure` (строки 53–71 валидатора) и прогоняет через него каждый элемент |
| 4 | Фикстура разошлась с кодом: `Routing::Attempt#to_h` даёт другой набор ключей | JSON в `spec/fixtures` никто не парсит через наш код | P2, проверка 8: round-trip `Attempt#to_h → JSON → parse` равен элементу фикстуры |
| 5 | Изобретена своя формулировка `reason` | валидатор сверяет skip-причины только предупреждениями (⚠️), не ошибками — билд остаётся зелёным | P1: `Reasons::SKIP` заморожен, спек проверяет, что причины из `reference_decisions.json` — его подмножество; P2: `reason` фикстур ∈ `SKIP`/`SELECTED` |
| 6 | Заглушка `bin/route` со `spacepayments` доживает до Ф2 и выглядит как рабочий движок | файлы валидны, покрытие полное, `make gate` зелёный | Контрольная цифра «ровно 4 ошибки» в P4 + `TODO(Ф1/R-11)` в коде; гейт Ф1 требует 0 ошибок, заглушка его не проходит |
| 7 | Вывод перестал быть побайтово воспроизводимым (порядок ключей из хеша, экранирование кириллицы, плавающая дата) | JSON остаётся валидным, валидатор ничего не заметит | P4: явный порядок ключей, `period` из данных а не из текущего момента; спек 6 на два прогона; `make determinism` в гейте |
| 8 | `make validate` запущен на другой очереди и дал ложную картину | валидатор жёстко читает `operations_queue_10.json`, но об этом не сообщает | P4: цель `validate` прибита к public-очереди, `$(QUEUE)` из неё убран; противоречие C-B зафиксировано в плане |
| 9 | `Gemfile` с пином Ruby ломает либо CI (3.3), либо локальную машину (4.0.6) | падение выглядит как «проблема окружения», а не как решение в коде | P0: директивы `ruby` в `Gemfile` нет, `TargetRubyVersion: 3.3` в RuboCop; `Gemfile.lock` в репозитории |
| 10 | Слово `sample`/`rand` в комментарии заглушки валит CI на ровном месте | падает не тот пакет, который его внёс | Явный запрет в брифе P1 и P4 на эти слова в комментариях внутри `lib/routing`, `lib/execution` |
| 11 | Порядок спеков `:random` даёт мигающий сьют | падение раз в N прогонов списывают на «флак» | P0: `config.order = :defined` |
| 12 | Артефакты `routing_*_test.json` закоммичены с результатом public-очереди | имена правильные, файлы валидные, но содержимое не то, что ждут организаторы | Вариант C (§1 C-A): рабочие прогоны пишут в `out/`, корень наполняет только `make deliver`; пункт 6 гейта фазы |

---

## 8. Итоговый список пакетов

| Порядок | Пакет | ID из TASKS.md | Владелец по OWNERSHIP | Проверка |
|---|---|---|---|---|
| 1 | P0 — скелет репозитория | C-3 | Максим | `make gate` |
| 2 | P1 — семь интерфейсов и словарь причин | C-1 | Вова | `make gate` |
| 2' | P4 — `bin/route` и два файла (параллельно P1) | C-5 | Кирилл | `make gate`, `make validate` → ровно 4 ошибки |
| 3 | P2 — три фикстуры форматов | C-2 | Вова | `make gate` |
| 3' | P3 — защита от недетерминизма (параллельно P2) | C-4 | Максим | негативный тест с файлом-зондом |
| 4 | P5 — гейт фазы | — | — | сводная команда §6 |
