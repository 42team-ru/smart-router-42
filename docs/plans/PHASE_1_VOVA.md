# Ф1 — Допуск. План работ Вовы (R-1 … R-11)

Источники: `docs/SCOPE.md` → `docs/ARCHITECTURE.md` → `docs/TASKS.md` (раздел «Ф1 — Первый
валидный файл» и «Роли в фазе Ф1») → `docs/OWNERSHIP.md`, `AGENTS.md`,
`docs/PROMPT_ORCHESTRATOR.md`, `docs/plans/PHASE_0.md`, `reference/scripts/validate_10.rb`,
`reference/data/{providers,operations_queue_10,reference_decisions}.json`.

**Зона плана.** Только задачи Вовы: R-1 … R-11 — девять hard-constraints, реестр с
фиксированным порядком и `RoutePlan` + построитель плана. Задачи IO-*, E-*, A-*, T-* в план
не входят, они перечислены отдельно как точки стыка (§2).

**Гейт фазы (из TASKS.md):** `make validate` → 0 ошибок, все четыре эталонных кейса
зелёные. Ф0 оставила ровно `✅ Пройдено: 12 / ❌ Ошибок: 4 / ⚠️ Предупр.: 13`, где четыре
ошибки — это op_103, op_104, op_107, op_108. Задача фазы: 4 → 0, и заодно 13 предупреждений
→ 0, потому что все 13 — это `нет attempt для <provider>` по `skip_reasons_expected`.

---

## 0. Фактическое состояние репозитория (проверено чтением, не по памяти)

Ф0 закрыта, в `main` лежит:

- `lib/routing/constraints/base.rb` — `Base.violation(provider, operation, state)`,
  **классовый** метод, поднимает `NotImplementedError`. Сигнатура заморожена и проверяется
  `spec/contracts/interfaces_spec.rb` по `parameters` дословно.
- `lib/routing/constraints.rb` — модуль с `REASONS = Reasons::SKIP` и комментарием
  «REGISTRY появляется в задаче R-10». Реестра нет намеренно.
- `lib/routing/reasons.rb` — `SKIP` (10 строк) и `SELECTED` (5 строк), обе заморожены.
- `lib/routing/violation.rb` — `Violation = Data.define(:reason, :details)` с
  `#to_attempt(provider)` → `Attempt(decision: 'skipped')`. **Готово, переписывать не надо.**
- `lib/routing/attempt.rb` — `decision` валидируется (`ArgumentError` на чужое значение),
  `#to_h` с фиксированным порядком ключей.
- `lib/routing/route_plan.rb` — **уже реализован**: конструктор с `operation:/candidates:/
  skipped:`, валидация дублей и пересечения, `#attempt_no_for`, `#empty?`, `freeze`.
  То есть R-11 — это не «написать RoutePlan», а «построить план и подключить его».
- `lib/domain/provider.rb` — `Data.define` из 24 полей, `#name` = `payment_system`,
  комментарий про `nil` = «ограничения нет».
- `lib/domain/operation.rb` — `operation_id, created_at, amount, bank, card_brand,
  payout_requisite`.
- `lib/state/providers.rb`, `lib/execution/*`, `lib/routing/strategies|layers/base.rb` —
  заглушки с `NotImplementedError`. Чужая зона, в Ф1 Вова их не трогает.
- `spec/spec_helper.rb` — `config.order = :defined`, `$LOAD_PATH` на `lib/`, хелперы
  `fixture_path`, `reference_path`. Каталога `spec/support/` **нет**, автозагрузки хелперов
  нет — подключение делается явным `require`.
- `bin/route` — заглушка Ф0: каждой операции назначается `spacepayments`, в коде стоит
  `# TODO(Ф1/R-11): заменить на настоящий RoutePlan + Executor`. Снятие этого TODO — часть
  пакета V7.
- `Makefile`: `gate = test lint no-random`; `validate` жёстко прибит к
  `reference/data/operations_queue_10.json`, `OUT ?= out/routing_decisions_test.json`.
- `.github/workflows/tests.yml`: на шаге `make validate` стоит `continue-on-error: true` с
  комментарием «пометка снимается гейтом Ф1». **Снятие пометки входит в гейт Ф1** (§8).
- `lib/io/` не существует: загрузчиков Кирилла ещё нет.

---

## 1. Противоречия в постановке (называю, не решаю молча)

### C-1. Кто пишет `details`: Вова (R-1…R-9) или Кирилл (A-2)

`TASKS.md` даёт Вове девять ограничений с дословными причинами, а Кириллу — A-2
«Форматтер `details` — число в каждой причине, "52000 > limit_amount_max 50000" для каждой
из 10 причин». Это один и тот же текст, написанный дважды.

| | Вариант A (рекомендуемый): текст в ограничениях | Вариант B: ограничение отдаёт числа, форматирует A-2 |
|---|---|---|
| Что делает Вова | `Violation.new(reason:, details:)` собирается прямо в constraint | constraint отдаёт `Violation` с машинным `details`-хешем |
| Что делает Кирилл (A-2) | спек-страж: все 10 причин из реального прогона содержат цифру; словарь метрик отчёта | формат строки и её сборка |
| Плюс | `Violation` из Ф0 (`Data.define(:reason, :details)`) не меняется, интерфейсный спек Ф0 остаётся зелёным | формат в одном месте |
| Минус | текст размазан по девяти файлам — лечится общим хелпером `Routing::Details` | ломает замороженный на Ф0 контракт `Violation`, значит правку `interfaces_spec` и согласование с Максимом и Кириллом посреди фазы |

**В план заложен вариант A.** Общий хелпер `Routing::Details` (пакет V1) держит текст в
одном месте, а `Violation` остаётся ровно таким, каким его заморозила Ф0.

### C-2. `state` в сигнатуре есть, а `State::Providers` — заглушка

`Constraint.violation(provider, operation, state)` заморожен на Ф0, но `State::Providers`
до E-1 (Максим) поднимает `NotImplementedError` на любом методе. Восьми из девяти
ограничений `state` не нужен: все счётчики (`daily_approved_amount`, `in_progress_count`,
`in_progress_amount`) лежат **в самом `Domain::Provider`** — это снимок на момент операции,
и именно так их читает валидатор (строки 34–36). Единственный потребитель `state` — R-9
`RateLimit`, которому нужен счётчик запросов за минуту.

**Решение:** `state` — необязательный источник, читается только через утиный вызов, и
**отсутствие данных не отсеивает никого** (инвариант C-G из `PHASE_0.md`). Точная
сигнатура, которую Вова просит у Максима, — в §2, стык S-2. До её появления R-9 не
срабатывает ни на ком, и это проверяется спеком, а не надеждой.

### C-3. Кто снимает `TODO(Ф1/R-11)` из `bin/route`

`bin/route` — файл Кирилла (C-5 → A-1), но задание фазы требует снять TODO в рамках R-11,
а `Planner` без вызова из CLI не двигает `make validate` ни на одну ошибку.

| | Вариант A (рекомендуемый) | Вариант B |
|---|---|---|
| Кто | V7 (Вова) правит `bin/route` минимально: замена `build_decision` на `Planner` + выбор первого кандидата; блок отчёта не трогается | TODO снимает Кирилл в A-1, V7 отдаёт только `Planner` |
| Условие | IO-1/IO-2 Кирилла уже в `main` (по TASKS.md они первые в его очереди) | ничего не ждём |
| Плюс | гейт Ф1 достижим силами одного пакета, 4 ошибки → 0 измеряются сразу | ноль правок в чужой зоне |
| Минус | правка в зоне Кирилла — предупредить его до старта V7 | «0 ошибок» не проверяется до конца фазы, а это и есть гейт |

**В план заложен вариант A.** Если IO-1 не готов к моменту V7 — см. §5, бриф V7,
раздел «если загрузчиков ещё нет».

### C-4. `spacepayments` и проверка `TrafficShare`

Валидатор (строка 31) исключает `spacepayments` из фильтра нулевого трафика, то есть
считает его допустимым всегда. Но `reference_decisions.json → eligible_providers` его
нигде не перечисляет, а четыре эталонных кейса требуют внешнего провайдера. Инвариант
`AGENTS.md`: «spacepayments — fallback по допуску, а не по исходу».

**Решение, зафиксированное для всей фазы:** `TrafficShare` возвращает `nil` для
fallback-провайдера (повторяет строку 31 валидатора), но **`Planner` строит каскад только
из внешних провайдеров**. `spacepayments` не попадает ни в `candidates`, ни в `skipped`;
он подставляется отдельно и только когда `plan.empty?`. Имя fallback-провайдера — параметр
(`fallback_provider:`, по умолчанию `"spacepayments"`), а не строковый литерал в девяти
местах.

---

## 2. Точки стыка с чужими зонами

Вова пишет против фикстур Ф0 и `reference/data/*`, пока не появились загрузчики Кирилла.

| ID | Стык | Кто отдаёт | Что делает Вова до этого |
|---|---|---|---|
| S-1 | `Domain::Provider` / `Domain::Operation` из JSON | IO-1, IO-2 (Кирилл) | `spec/support/provider_factory.rb` — фабрика с дефолтами public-снапшота; `reference_path('providers.json')` читается спеком напрямую. Фабрика живёт **только в `spec/`**, в `lib/` не переезжает никогда |
| S-2 | счётчик запросов в минуту для R-9 | E-1 (Максим) | утиный вызов `state.respond_to?(:requests_in_minute)` → `state.requests_in_minute(provider_name, minute_key)` → `Integer` или `nil`. `nil`, отсутствие метода, отсутствие `requests_per_minute_limit` — **никого не отсекают**. `minute_key` считает сам constraint из `operation.created_at`, не из текущего момента |
| S-3 | `RoutePlan` → `Executor#run(plan, operation, state)` | E-2, E-4 (Максим) | `RoutePlan` из Ф0 не меняется. V7 добавляет **новый** класс `Routing::Planner`, интерфейсный спек Ф0 остаётся зелёным |
| S-4 | `Violation#to_attempt` → `decisions_writer` | A-1 (Кирилл) | контракт Ф0, не трогается; порядок `attempts` = порядок `skipped` из плана, затем `selected` |
| S-5 | `details` с числом в каждой из 10 причин | A-2 (Кирилл) | вариант A из C-1: текст пишет Вова, A-2 проверяет и потребляет |
| S-6 | `Strategy#rank` заменит порядок каскада | S-0, S-1, S-2 (Ф2) | в Ф1 порядок каскада — по возрастанию `priority`, это **временная** политика, помеченная в коде как `# Ф2/S-1: порядок заменит CountShare` |

---

## 3. Что заморожено в этой фазе и не обсуждается

### 3.1 Десять причин отсева — дословно

Из `reference/data/reference_decisions.json` и `lib/routing/reasons.rb` (`Reasons::SKIP`).
Реально встречаются в `skip_reasons_expected` три: `bank_not_in_list`,
`amount_exceeds_limit`, `amount_below_minimum` — их валидатор сверяет посимвольно.
Остальные семь наши, но словарь общий и заморожен:

```
provider_inactive  zero_traffic_share  amount_below_minimum  amount_exceeds_limit
daily_limit_exceeded  in_progress_limit_exceeded  bank_not_in_list  negative_margin
no_requisites  rate_limit_exceeded
```

Свою формулировку изобретать запрещено. `reason` берётся **только** из
`Routing::Reasons::SKIP`, спек реестра проверяет это множеством.

### 3.2 «Причина без числа не принимается» — канонический вид `details`

Каждый `details` содержит хотя бы одну цифру и конкретное сравнение. Канон фазы (кодер
воспроизводит дословно, `<...>` — подстановка):

| reason | details |
|---|---|
| `provider_inactive` | `status <status> != active (1 допустимый статус)` |
| `zero_traffic_share` | `traffic_percentage <v> == 0` |
| `amount_below_minimum` | `<amount> < limit_amount_min <min>` |
| `amount_exceeds_limit` | `<amount> > limit_amount_max <max>` |
| `daily_limit_exceeded` | `daily_approved_amount <d> + <amount> = <sum> > daily_amount_limit <lim>` |
| `in_progress_limit_exceeded` (count) | `in_progress_count <c> + 1 = <sum> > in_progress_count_limit <lim>` |
| `in_progress_limit_exceeded` (amount) | `in_progress_amount <a> + <amount> = <sum> > in_progress_amount_limit <lim>` |
| `bank_not_in_list` (белый список) | `bank <bank> не входит в banks [<b1>, <b2>] (<n> банков)` |
| `bank_not_in_list` (чёрный список) | `bank <bank> входит в exclude_banks [<...>] (<n> банков)` |
| `negative_margin` | `provider_margin_pct <p> > merchant_margin_pct <m>, allow_negative_agreement false` |
| `no_requisites` | `available_requisites 0 == 0` |
| `rate_limit_exceeded` | `запросов за минуту <k> + 1 = <sum> > requests_per_minute_limit <lim>` |

Две причины (`provider_inactive`, `no_requisites`) числа по природе не имеют — поэтому
канон встраивает в них счётную величину. Это не украшение: `spec` каждой проверки требует
`details =~ /\d/`, и `fixtures_spec.rb` Ф0 уже проверяет то же самое для фикстур.

### 3.3 Порядок реестра и его обоснование

```ruby
REGISTRY = [Status, TrafficShare, AmountRange, DailyLimit,
            InProgress, BankFilter, Margin, Requisites, RateLimit].freeze
```

Порядок — из `ARCHITECTURE.md` §5, но он не декоративный: `Constraints.check` возвращает
**первое** нарушение, и оно попадает в `attempts` как единственная причина. Проверяемое
следствие в данных: **op_103 (150 000 ₽), payflow** нарушает сразу две проверки —
`150000 > limit_amount_max 50000` и `2 900 000 + 150 000 = 3 050 000 > 3 000 000`.
`reference_decisions.json → skip_reasons_expected["op_103"]["payflow"]` требует
`amount_exceeds_limit`. Значит **AmountRange обязан стоять раньше DailyLimit** — иначе
валидатор выдаст предупреждение, а гейт останется формально зелёным. Это ровно тот случай,
который ломается молча (§7, строка 1).

Остальные позиции: `Status` первым — у выключенного провайдера бессмысленно докладывать про
банк; `RateLimit` последним — единственная проверка на поле, которого нет в снапшоте
организаторов, она не имеет права маскировать настоящую причину.

### 3.4 Детерминизм и целочисленная арифметика

- В `lib/routing/` запрещены `rand`, `shuffle`, `sample`, `Time.now` — **включая
  комментарии и имена**: `make no-random` грепает по словам. Минута для R-9 берётся из
  `operation.created_at`, а не из текущего момента.
- Суммы — `Integer`, сравнения прямые. Никаких `to_f` в решающем пути.
- Проценты и маржа приходят как `1.2`/`1.5`. Сравнение — через
  `Rational(value.to_s)`, не через `Float#>`. `Float` допускается только в тексте `details`
  (там это ввод-вывод, а не решение).
- Ни одна проверка не итерируется по хешу: `REGISTRY` — замороженный массив, порядок
  `skipped` = порядок провайдеров во входном снапшоте.
- `nil` в лимите = «ограничения нет» = проверка не срабатывает. Это не то же, что `0`.

---

## 4. Пакеты работ

| ID | Пакет | TASKS | Зависит | Проверяется одной командой |
|---|---|---|---|---|
| V1 | `Routing::Details` + `Status`, `TrafficShare`, `Requisites` + фабрика провайдера для спеков | R-1, R-2, R-8 | Ф0 | `make gate` |
| V2 | `AmountRange` (две причины) + `DailyLimit` | R-3, R-4 | V1 | `make gate` |
| V3 | `InProgress` (count и amount) + `Margin` | R-5, R-7 | V1 | `make gate` |
| V4 | `BankFilter`: пустой список / белый / чёрный / неизвестный банк | R-6 | V1 | `make gate` |
| V5 | `RateLimit` на утином `state`, `nil` никого не отсекает | R-9 | V1 | `make gate` |
| V6 | `REGISTRY` + `Constraints.check` + спек паритета с `eligible_providers` по всем 10 операциям | R-10 | V1–V5 | `make gate` |
| V7 | `Routing::Planner` + подключение в `bin/route`, снятие `TODO(Ф1/R-11)` | R-11 | V6 (+ IO-1/IO-2) | `make gate` и `make validate` → `❌ Ошибок:   0` |

Граф:

```
V1 ──┬── V2 ──┐
     ├── V3 ──┤
     ├── V4 ──┼── V6 ── V7
     └── V5 ──┘
```

V2, V3, V4, V5 после V1 независимы между собой (разные файлы, общий только хелпер и
фабрика). Кодеру всё равно отдаются по одному.

---

## 5. Брифы кодеру

Каждый бриф самодостаточен: кодер плана не видел.

---

### БРИФ V1 — базовые проверки допуска: Status, TrafficShare, Requisites (R-1, R-2, R-8)

**Контекст.** `smart-routing-42` — офлайн-движок роутинга выплат на чистом Ruby, без
Rails, БД и веба. Одна операция проходит стадию «допуск»: набор независимых
hard-constraints решает, какие провайдеры вообще могут её взять. Ты пишешь первые три
проверки и общий хелпер текста причин. Стратегии, каскад и состояние — не твоя задача в
этом пакете, их не трогай.

**Что уже есть (читать, не переписывать):**

- `lib/routing/constraints/base.rb` — базовый класс, **классовый** метод
  `self.violation(provider, operation, state)`, поднимает `NotImplementedError`.
- `lib/routing/violation.rb` — `Violation = Data.define(:reason, :details)`.
- `lib/routing/reasons.rb` — `Routing::Reasons::SKIP`, 10 замороженных строк.
- `lib/domain/provider.rb` — `Data.define` из 24 полей, `#name` = `payment_system`.
- `lib/domain/operation.rb` — `operation_id, created_at, amount, bank, card_brand,
  payout_requisite`.
- `spec/spec_helper.rb` — `$LOAD_PATH` уже содержит `lib/`, есть `fixture_path(*parts)` и
  `reference_path(*parts)` (последний указывает в `reference/data`). Автозагрузки
  `spec/support` нет: подключай явным `require_relative`.

**Жёсткие запреты для всего, что лежит в `lib/routing/`:** слова `rand`, `shuffle`,
`sample`, `Time.now` не должны встречаться даже в комментариях и именах — CI валит билд по
грепу. Все файлы начинаются с `# frozen_string_literal: true`.

**Создать `lib/routing/details.rb`** — модуль `Routing::Details`, единственное место, где
живёт текст причин. Правило проекта: **причина без числа не принимается**, каждый `details`
обязан содержать хотя бы одну цифру и конкретное сравнение. Методы модуля (все —
`module_function`, чистые, возвращают `String`):

```ruby
Routing::Details.inactive(status)                          # "status suspended != active (1 допустимый статус)"
Routing::Details.zero_traffic(value)                       # "traffic_percentage 0 == 0"
Routing::Details.no_requisites(value)                      # "available_requisites 0 == 0"
Routing::Details.below_min(amount, min)                    # "800 < limit_amount_min 1000"
Routing::Details.above_max(amount, max)                    # "150000 > limit_amount_max 100000"
Routing::Details.sum_over(field, current, delta, limit_field, limit)
#   "daily_approved_amount 2900000 + 150000 = 3050000 > daily_amount_limit 3000000"
Routing::Details.bank_not_allowed(bank, banks)             # "bank alfa не входит в banks [sberbank, tinkoff, vtb] (3 банка)"
Routing::Details.bank_excluded(bank, banks)                # "bank sberbank входит в exclude_banks [sberbank] (1 банк)"
Routing::Details.negative_margin(provider_pct, merchant_pct)
#   "provider_margin_pct 1.8 > merchant_margin_pct 1.5, allow_negative_agreement false"
```

В этом пакете реализуй все девять методов сразу (остальные проверки их подхватят
следующими пакетами) и покрой их спеком. Склонение слова «банк» не выдумывай: используй
форму `(3 банка)` при 2–4 и `(5 банков)` иначе, `(1 банк)` при единице — это чистая
арифметика, проверяемая спеком.

**Создать три проверки.** Каждая — отдельный файл, класс наследует
`Routing::Constraints::Base`, реализует `self.violation(provider, operation, state)`,
возвращает `nil` (провайдер проходит) или `Routing::Violation`.

1. `lib/routing/constraints/status.rb` → `Routing::Constraints::Status`.
   Отсев, если `provider.status != "active"`. `reason: "provider_inactive"`.
   `nil` в `status` считается неактивным.
2. `lib/routing/constraints/traffic_share.rb` → `Routing::Constraints::TrafficShare`.
   Отсев, если `traffic_percentage` равен нулю или `nil`. `reason: "zero_traffic_share"`.
   **Исключение:** провайдер-fallback. Имя fallback-провайдера — аргумент по умолчанию
   через константу `Routing::Constraints::TrafficShare::FALLBACK_PROVIDER = "spacepayments"`,
   для него метод возвращает `nil` независимо от трафика. Это повторяет строку 31
   валидатора организаторов, который считает `spacepayments` допустимым всегда.
3. `lib/routing/constraints/requisites.rb` → `Routing::Constraints::Requisites`.
   Отсев, если `available_requisites` равен нулю или `nil`. `reason: "no_requisites"`.
   Отрицательное значение тоже отсев.

**Инварианты, обязательные для всех проверок фазы:**

- `reason` берётся **только** из `Routing::Reasons::SKIP`, дословно. Свои формулировки
  запрещены: валидатор организаторов сверяет причины посимвольно.
- `nil` в поле лимита означает «ограничения нет», а не ноль: так устроен провайдер
  `spacepayments`, у которого все лимиты `null`. Проверка, параметра которой нет, не
  отсеивает никого. Для `Status`, `TrafficShare`, `Requisites` это правило звучит иначе —
  там `nil` значит «данных нет, провайдер не годен», и это осознанная асимметрия: лимит
  без значения — это отсутствие ограничения, а статус без значения — отсутствие допуска.
- Никакой арифметики с плавающей точкой в решении: суммы целые, проценты сравниваются
  через `Rational(value.to_s)`.
- Проверка не обращается к будущим операциям очереди и ничего не пишет в состояние.

**Создать `spec/support/provider_factory.rb`** — хелпер для спеков (в `lib/` он не
переезжает никогда). Модуль `ProviderFactory` с методом
`build_provider(**overrides) -> Domain::Provider`: дефолты берутся с провайдера `vipay`
из `reference/data/providers.json` (`status: "active"`, `traffic_percentage: 40`,
`priority: 1`, `limit_amount_min: 1000`, `limit_amount_max: 100_000`,
`daily_amount_limit: 5_000_000`, `daily_approved_amount: 3_200_000`,
`in_progress_count_limit: 10`, `in_progress_count: 4`,
`in_progress_amount_limit: 1_000_000`, `in_progress_amount: 380_000`,
`available_requisites: 12`, `conversion_24h: 0.87`, `avg_latency_sec: 38`,
`banks: %w[sberbank tinkoff vtb]`, `exclude_banks: false`, `provider_margin_pct: 1.2`,
`merchant_margin_pct: 1.5`, `allow_negative_agreement: false`, остальные четыре поля —
`volume_share_pct: nil`, `requests_per_minute_limit: nil`, `daily_turnover_min: nil`,
`daily_turnover_max: nil`). Плюс `build_operation(**overrides) -> Domain::Operation`
с дефолтами op_101 (`operation_id: "op_101"`,
`created_at: "2026-07-30T09:05:00+03:00"`, `amount: 15_000`, `bank: "sberbank"`,
`card_brand: nil`, `payout_requisite: {}`). Фабрика нужна потому, что `Data.define`
требует все поля разом, и без неё каждый спек превратится в двадцать строк шума.

**Спеки, которые надо написать:**

- `spec/routing/details_spec.rb` — по одному примеру на каждый из девяти методов: строка
  совпадает дословно с образцом выше **и** удовлетворяет `/\d/`. Отдельный пример на
  склонение: 1 → «банк», 3 → «банка», 5 → «банков».
- `spec/routing/constraints/status_spec.rb` — `active` → `nil`; `suspended` → `Violation` с
  `reason == "provider_inactive"` и `details` с цифрой; `nil` → `Violation`.
- `spec/routing/constraints/traffic_share_spec.rb` — 40 → `nil`; 0 → `Violation`
  (`zero_traffic_share`); `nil` → `Violation`; **провайдер с именем `spacepayments` и
  `traffic_percentage: 0` → `nil`**.
- `spec/routing/constraints/requisites_spec.rb` — 12 → `nil`; 0 → `Violation`
  (`no_requisites`); `nil` → `Violation`.
- В каждом спеке проверок — общий пример: `violation.reason` входит в
  `Routing::Reasons::SKIP`.

Спеки вызывают проверку с `state = nil`: этим трём проверкам состояние не нужно, и спек
обязан это зафиксировать.

**Критерий приёмки (одна команда):**

```
make gate
```

Успех: `0 failures`, `no offenses detected`, `детерминизм: источников случайности нет`,
число примеров выросло относительно предыдущего прогона. Ненулевой exit — FAIL.

---

### БРИФ V2 — AmountRange и DailyLimit (R-3, R-4)

*(выдаётся после PASS V1)*

**Задача.** Две проверки допуска. Файлы: `lib/routing/constraints/amount_range.rb`,
`lib/routing/constraints/daily_limit.rb`. Обе наследуют
`Routing::Constraints::Base`, реализуют `self.violation(provider, operation, state)`,
возвращают `nil` или `Routing::Violation`. Текст причин — только через
`Routing::Details`.

`AmountRange` даёт **две разные причины** одним классом:
`operation.amount < provider.limit_amount_min` → `amount_below_minimum`
(`Details.below_min`); `operation.amount > provider.limit_amount_max` →
`amount_exceeds_limit` (`Details.above_max`). Минимум проверяется первым. `nil` в любом из
двух лимитов = ограничения нет.

`DailyLimit`: отсев, если `daily_approved_amount + amount > daily_amount_limit`, причина
`daily_limit_exceeded`, `details` — `Details.sum_over("daily_approved_amount",
daily_approved_amount, amount, "daily_amount_limit", daily_amount_limit)`. Строгое `>`:
равенство лимиту проходит. Так же считает валидатор организаторов (строка 34). `nil` в
`daily_amount_limit` = ограничения нет; `nil` в `daily_approved_amount` читается как 0.

**Арифметика только целочисленная.** Никаких `to_f`: копейки в данных отсутствуют, суммы —
целые рубли.

**Спеки:** `spec/routing/constraints/amount_range_spec.rb`,
`spec/routing/constraints/daily_limit_spec.rb`, оба через `ProviderFactory` из
`spec/support/provider_factory.rb`.

`amount_range_spec` обязан содержать три граничных примера и два кейса из реальных данных:
сумма ровно `limit_amount_min` → `nil`; ровно `limit_amount_max` → `nil`; `min - 1` →
`amount_below_minimum`; **op_107: `amount: 800` при `limit_amount_min: 1000` →
`amount_below_minimum` с `details == "800 < limit_amount_min 1000"`**; **op_103:
`amount: 150_000` при `limit_amount_max: 100_000` → `amount_exceeds_limit` с
`details == "150000 > limit_amount_max 100000"`**. Плюс: оба лимита `nil` → `nil` при любой
сумме (так устроен spacepayments).

`daily_limit_spec`: сумма, ровно добивающая до лимита, проходит; на рубль больше — отсев;
`daily_amount_limit: nil` → `nil`; **payflow из public-снапшота
(`daily_approved_amount: 2_900_000`, `daily_amount_limit: 3_000_000`) с суммой 150 000 →
`details == "daily_approved_amount 2900000 + 150000 = 3050000 > daily_amount_limit
3000000"`**.

**Критерий приёмки:** `make gate` → `0 failures`, `no offenses detected`.

---

### БРИФ V3 — InProgress и Margin (R-5, R-7)

*(выдаётся после PASS V1)*

`lib/routing/constraints/in_progress.rb`: одна причина `in_progress_limit_exceeded`, два
условия. По количеству: `in_progress_count + 1 > in_progress_count_limit` (валидатор,
строка 35 — именно `+ 1`, а не `>=`). По сумме: `in_progress_amount + amount >
in_progress_amount_limit` (строка 36). Проверяется сначала количество, затем сумма — первая
сработавшая формирует `details` через `Details.sum_over`. `nil` в любом лимите = нет
ограничения; `nil` в счётчике = 0.

`lib/routing/constraints/margin.rb`: отсев, если `provider_margin_pct > merchant_margin_pct`
**и** `allow_negative_agreement` не истинно. Причина `negative_margin`. Сравнение процентов
— **через `Rational(value.to_s)`, не через `Float`**: решающий путь обязан быть
целочисленным/точным, `1.2` и `1.5` в JSON — это десятичные дроби, а не приближения.
`nil` в любом из процентов = проверка не срабатывает.

**Спеки** `spec/routing/constraints/in_progress_spec.rb` и
`spec/routing/constraints/margin_spec.rb`:

- in_progress: последний влезающий слот проходит (count `9` при лимите `10`), следующий —
  отсев; сумма ровно до лимита проходит, +1 рубль — отсев; оба лимита `nil` → `nil`;
  `details` содержит цифру и обе стороны сравнения.
- margin: `1.2 > 1.5` ложно → `nil`; `1.8` против `1.5` → `Violation`; `1.8` против `1.5`
  с `allow_negative_agreement: true` → `nil`; равные проценты → `nil` (строгое `>`);
  отдельный пример: сравнение выполняется точно — `provider_margin_pct: 0.1 + 0.2`
  не должно вести себя иначе, чем `0.3` (если реализация ушла во `Float`, пример упадёт).

**Критерий приёмки:** `make gate` → `0 failures`, `no offenses detected`.

---

### БРИФ V4 — BankFilter (R-6)

*(выдаётся после PASS V1)*

`lib/routing/constraints/bank_filter.rb`, причина `bank_not_in_list`, три ветки —
буквально по строкам 40–47 валидатора организаторов:

1. `banks` пуст или `nil` → **проходят все банки**, `nil`;
2. `exclude_banks == true` → список чёрный: отсев, если `banks.include?(operation.bank)`,
   `details` — `Details.bank_excluded`;
3. иначе список белый: отсев, если `banks` не содержит `operation.bank`, `details` —
   `Details.bank_not_allowed`.

Отдельно: **неизвестный банк** (значение, которого нет ни у кого) проходит только у
провайдеров с пустым `banks` — это следствие ветки 3, но спек обязан его зафиксировать
явно. Сравнение имён банков — строгое, без нормализации регистра: данные организаторов
приходят в нижнем регистре, самодеятельная нормализация замаскировала бы расхождение.

**Спек** `spec/routing/constraints/bank_filter_spec.rb`, обязательные примеры на реальных
данных public-снапшота:

- vipay (`banks: %w[sberbank tinkoff vtb]`, `exclude_banks: false`) и `bank: "alfa"`
  (op_102) → `bank_not_in_list`, `details ==
  "bank alfa не входит в banks [sberbank, tinkoff, vtb] (3 банка)"`;
- vipay и `bank: "gazprombank"` (op_104) → отсев; payflow (`banks: %w[sberbank alfa]`) и
  `gazprombank` → отсев; quickpay (`banks: []`) и `gazprombank` → `nil`;
- vipay и `bank: "raiffeisen"` (op_108) → отсев;
- vipay и `bank: "sberbank"` → `nil`;
- чёрный список: `banks: %w[sberbank], exclude_banks: true`, `bank: "sberbank"` → отсев,
  `bank: "alfa"` → `nil`;
- `banks: nil` → `nil` при любом банке.

**Критерий приёмки:** `make gate` → `0 failures`, `no offenses detected`.

---

### БРИФ V5 — RateLimit (R-9)

*(выдаётся после PASS V1)*

**Контекст.** `requests_per_minute_limit` в снапшоте организаторов **отсутствует** — это
поле мы завели сами (ТЗ разрешает). Значит проверка обязана быть безопасной по умолчанию:
пока нет ни лимита, ни счётчика — она не отсеивает никого.

`lib/routing/constraints/rate_limit.rb`, причина `rate_limit_exceeded`.

Алгоритм:

1. `limit = provider.requests_per_minute_limit`; `nil` → вернуть `nil` (ограничения нет);
2. счётчик берётся у состояния утиным вызовом: если `state` не `nil` и
   `state.respond_to?(:requests_in_minute)` — `count = state.requests_in_minute(
   provider.name, minute_key)`, иначе `count = nil`; `nil` → вернуть `nil`;
3. отсев, если `count + 1 > limit`; `details` — `Details.sum_over("запросов за минуту",
   count, 1, "requests_per_minute_limit", limit)`.

`minute_key` — **первые 16 символов `operation.created_at`** (`"2026-07-30T09:05"`), то
есть минута берётся из данных операции. Обращение к текущему моменту здесь запрещено:
вывод обязан быть побайтово воспроизводимым на двух прогонах, и CI валит билд по грепу на
соответствующие имена методов. Вынеси вычисление в публичный метод
`Routing::Constraints::RateLimit.minute_key(operation) -> String`, чтобы его можно было
проверить спеком отдельно.

Интерфейс `requests_in_minute(provider_name, minute_key) -> Integer | nil` — это то, что
позже реализует владелец `State::Providers`. Сейчас его нет ни у кого, и это нормально.

**Спек** `spec/routing/constraints/rate_limit_spec.rb`:

- `requests_per_minute_limit: nil`, `state = nil` → `nil`;
- лимит 7, `state = nil` → `nil` (нет счётчика — нет отсева);
- лимит 7, состояние-дубль без метода `requests_in_minute` → `nil`;
- лимит 7, дубль возвращает 6 → `nil` (`6 + 1 = 7`, не больше лимита);
- лимит 7, дубль возвращает 7 → `Violation` с `reason == "rate_limit_exceeded"` и
  `details` с цифрой;
- лимит 7, дубль возвращает `nil` → `nil`;
- `minute_key(build_operation(created_at: "2026-07-30T09:05:30+03:00")) == "2026-07-30T09:05"`.

Дубль состояния делай обычным объектом или `instance_double` от `Object` — не заводи
зависимость от `State::Providers`, он сейчас заглушка с `NotImplementedError`.

**Критерий приёмки:** `make gate` → `0 failures`, `no offenses detected`.

---

### БРИФ V6 — REGISTRY и паритет с валидатором (R-10)

*(выдаётся после PASS V1–V5)*

**Задача.** Собрать девять проверок в реестр и доказать, что наш допуск совпадает с
допуском валидатора организаторов на всей публичной очереди.

**Изменить `lib/routing/constraints.rb`** (сейчас там только `REASONS` и комментарий
«REGISTRY появляется в задаче R-10»): подключить девять файлов, объявить

```ruby
REGISTRY = [Status, TrafficShare, AmountRange, DailyLimit,
            InProgress, BankFilter, Margin, Requisites, RateLimit].freeze

def self.check(provider, operation, state = nil)   # -> nil | Routing::Violation
def self.eligible?(provider, operation, state = nil) # -> true | false
```

`check` возвращает **первое** нарушение в порядке реестра и не выполняет оставшиеся
проверки (`REGISTRY.lazy.filter_map { ... }.first`).

**Порядок реестра менять нельзя, и вот почему** — это не стиль, а требование данных:
для op_103 провайдер payflow нарушает одновременно `AmountRange`
(`150000 > limit_amount_max 50000`) и `DailyLimit`
(`2900000 + 150000 > 3000000`), а `reference/data/reference_decisions.json`
(`skip_reasons_expected → op_103 → payflow`) требует именно `amount_exceeds_limit`.
`AmountRange` обязан стоять раньше `DailyLimit`. `Status` первым, `RateLimit` последним:
проверка на поле, которого нет в снапшоте организаторов, не имеет права закрывать собой
настоящую причину.

**Спек `spec/routing/constraints_registry_spec.rb`.** Это главный спек фазы, он ловит
расхождение с валидатором на нашем прогоне, а не за час до стопкода.

1. `REGISTRY` заморожен, содержит ровно 9 элементов, и их имена в **этом** порядке:
   `%w[Status TrafficShare AmountRange DailyLimit InProgress BankFilter Margin Requisites
   RateLimit]` (сравнение массивов, не множеств).
2. Каждый элемент реестра — наследник `Routing::Constraints::Base` и отвечает на
   `violation` с тремя параметрами.
3. `check` возвращает первое нарушение: провайдер, у которого одновременно
   `status: "suspended"` и `banks: []` не тот, даёт `provider_inactive`.
4. **Приоритет AmountRange над DailyLimit:** payflow из public-снапшота
   (`limit_amount_max: 50_000`, `daily_approved_amount: 2_900_000`,
   `daily_amount_limit: 3_000_000`) на сумме 150 000 даёт `amount_exceeds_limit`,
   а не `daily_limit_exceeded`.
5. Любая причина, которую способен вернуть реестр, входит в `Routing::Reasons::SKIP`.
6. **Паритет допуска.** Спек читает `reference/data/providers.json`,
   `reference/data/operations_queue_10.json` и `reference/data/reference_decisions.json`
   напрямую (загрузчиков `lib/io/` ещё нет — собери `Domain::Provider`/`Domain::Operation`
   прямо в спеке или переиспользуй `spec/support/provider_factory.rb`, добавив в него
   чтение снапшота). Для каждой из 10 операций множество внешних провайдеров
   (`vipay`, `payflow`, `quickpay` — то есть все, кроме `spacepayments`), для которых
   `Constraints.check` вернул `nil`, обязано **совпадать** с
   `reference_decisions["eligible_providers"][operation_id]`. Сравнение по отсортированным
   массивам, отдельный пример на каждую операцию (10 примеров, чтобы падение называло
   операцию).
7. Для каждой пары `(operation_id, provider)` из `skip_reasons_expected` наш
   `Constraints.check` возвращает **ровно ту же строку** `reason` (13 проверок).
   Это то место, где расхождение иначе прошло бы как жёлтое предупреждение валидатора,
   а не как ошибка.
8. `spacepayments` на исходном снапшоте проходит допуск для **всех** 10 операций
   (все лимиты `null`, трафик 0 не отсеивает fallback-провайдера).

Ожидаемые числа для сверки (уже посчитаны по данным, спек обязан их подтвердить, а не
подогнать): op_101 → `vipay, payflow, quickpay`; op_102 → `payflow, quickpay`;
op_103 → `quickpay`; op_104 → `quickpay`; op_105 → `vipay, quickpay`;
op_106 → `vipay, quickpay`; op_107 → `payflow`; op_108 → `quickpay`;
op_109 → `vipay, quickpay`; op_110 → `payflow, quickpay`.

**Инварианты.** Никаких `to_f` в решающем пути. `REGISTRY` — замороженный массив, порядок
`skipped` определяется порядком провайдеров во входных данных, а не порядком обхода хеша.
Слова `rand`, `shuffle`, `sample`, `Time.now` в `lib/routing/` запрещены даже в
комментариях.

**Критерий приёмки (одна команда):**

```
make gate
```

Успех: `0 failures`, `no offenses detected`, `детерминизм: источников случайности нет`.
Любое падение в примерах паритета — FAIL, «подправить ожидание в спеке» запрещено:
эталон — файл организаторов.

---

### БРИФ V7 — Planner и подключение к `bin/route` (R-11)

*(выдаётся после PASS V6)*

**Контекст.** Допуск готов: `Routing::Constraints.check(provider, operation, state)`
возвращает `nil` или `Routing::Violation`, `Routing::Constraints::REGISTRY` заморожен.
`Routing::RoutePlan` уже реализован (`initialize(operation:, candidates:, skipped:)`,
`#attempt_no_for`, `#empty?`, валидация дублей и пересечения — **не переписывай его**).
`bin/route` сейчас содержит заглушку с пометкой `# TODO(Ф1/R-11)`: каждой операции
назначается `spacepayments`. Валидатор организаторов на этой заглушке даёт ровно 4 ошибки.
Задача пакета — довести это число до нуля.

**1. Создать `lib/routing/planner.rb`** — `Routing::Planner`:

```ruby
Routing::Planner.new(providers:, fallback_provider: "spacepayments")
#   providers — Array<Domain::Provider> в порядке входного снапшота
#
#plan(operation, state = nil) -> Routing::RoutePlan
```

Алгоритм `#plan`:

1. Разделить провайдеров на внешних и fallback по имени (`provider.name`).
   Fallback в каскад и в `skipped` **не попадает никогда**.
2. Для каждого внешнего в порядке снапшота вызвать `Constraints.check`.
   `nil` → в кандидаты; `Violation` → в `skipped` парой `[provider, violation]`.
3. Кандидатов упорядочить **по возрастанию `priority`**, при равенстве — по имени по
   алфавиту. Это временная политика Ф1; над сортировкой оставь комментарий
   `# Ф2/S-1: порядок каскада заменит стратегия CountShare`. Никаких других соображений
   в порядок не закладывай.
4. Вернуть `RoutePlan.new(operation:, candidates:, skipped:)`.

Плюс метод `#fallback_provider_object -> Domain::Provider | nil` — тот самый провайдер из
`providers`, который используется, когда `plan.empty?`.

**Инварианты `Planner`:**

- В `candidates` не может попасть провайдер, у которого сработал допуск. В `skipped` не
  может попасть тот, кто прошёл. Пересечение пусто (`RoutePlan` это уже проверяет —
  не дублируй, но и не обходи).
- Планировщик не заглядывает в будущие операции очереди: обработка онлайновая, у каждой
  операции свой снимок.
- Ни `rand`, ни `shuffle`, ни `sample`, ни обращения к текущему моменту — ни в коде, ни в
  комментариях: CI грепает `lib/routing/` по этим словам.
- Сортировка детерминирована при равных `priority` (tie-break по имени), порядок `skipped`
  = порядок провайдеров во входном снапшоте.

**2. Подключить к `bin/route`**, сняв `TODO(Ф1/R-11)`. Меняются только функции построения
решения; блок построения отчёта (`build_report` и всё, что ниже), разбор аргументов и
запись файлов остаются как есть.

- Загрузить провайдеров: если в `main` уже есть загрузчик `lib/io/` (проверь наличие —
  его пишет другой разработчик), используй его. **Если загрузчика ещё нет** — не создавай
  ничего в `lib/io/`: сделай в `bin/route` приватную функцию
  `load_providers(path)`, читающую `reference/data/providers.json` и собирающую
  `Domain::Provider` (недостающие в снапшоте поля — `nil`), и пометь её
  `# TODO(IO-1): заменить на загрузчик из lib/io`. Путь к снапшоту — новая опция
  `--providers PATH` со значением по умолчанию `reference/data/providers.json`.
- Для каждой операции: построить план, собрать `attempts` = `skipped.map { |provider,
  violation| violation.to_attempt(provider.name).to_h }` **в порядке плана**, затем один
  элемент `selected`.
- Выбор: `plan.candidates.first`, если он есть, иначе fallback-провайдер.
  `reason` для выбранного: `"only_eligible_provider"`, если кандидат ровно один;
  `"first_eligible"`, если их больше; `"fallback_no_eligible_provider"`, если план пуст.
  Все три строки уже есть в `Routing::Reasons::SELECTED`, брать только оттуда.
  `details` обязан содержать число: `"допустимых провайдеров 1 из 3"`,
  `"допустимых провайдеров 2 из 3, первый по priority 1"`,
  `"допустимых внешних провайдеров 0 из 3"`.
- Ключи решения и их порядок не меняются: `operation_id`, `selected_provider`, `attempts`,
  `simulated_result`, `latency_sec`. Исполнение каскада и настоящие исходы в этом пакете
  не появляются — `simulated_result` остаётся `"approved"`, `latency_sec` берётся из
  `avg_latency_sec` выбранного провайдера (целое из снапшота, не выдуманное).
- `decision` в `attempts` принимает **только** `"selected"` и `"skipped"` — любое другое
  значение валидатор организаторов считает ошибкой структуры.

**3. Спек `spec/routing/planner_spec.rb`:**

1. на op_103 (150 000, sberbank) план содержит ровно одного кандидата `quickpay`, а в
   `skipped` — `vipay` и `payflow`, оба с `reason == "amount_exceeds_limit"`;
2. на op_107 (800, sberbank) единственный кандидат — `payflow`, `vipay` и `quickpay`
   отсеяны с `amount_below_minimum`;
3. `spacepayments` не появляется ни в `candidates`, ни в `skipped` ни для одной из 10
   операций публичной очереди;
4. если ни один внешний провайдер не прошёл (сконструируй такой снимок фабрикой),
   `plan.empty?` истинно, а `#fallback_provider_object` возвращает spacepayments;
5. порядок кандидатов для op_101 — `vipay, payflow, quickpay` (по `priority` 1, 2, 3);
6. при равных `priority` порядок задаётся именем по алфавиту (два прогона на перемешанном
   вручную входном массиве дают одинаковый результат);
7. `candidates` и `skipped` вместе покрывают всех внешних провайдеров снапшота и не
   пересекаются — для каждой из 10 операций.

**4. Спек `spec/bin/route_spec.rb` — дополнить** (файл существует, старые примеры не
удалять): после прогона на `reference/data/operations_queue_10.json`
`selected_provider` для op_103, op_104, op_108 равен `quickpay`, для op_107 — `payflow`;
ни одному решению не назначен `spacepayments`; для op_103 в `attempts` присутствуют
записи `vipay` и `payflow` с `decision == "skipped"`.

**5. `.github/workflows/tests.yml`:** снять `continue-on-error: true` с шага
`make validate` вместе с комментарием про Ф0 — с этого пакета валидатор обязан быть
зелёным в CI.

**Критерий приёмки (две команды, обе обязательны):**

```
make gate
make validate ; echo "EXIT=$?"
```

Успех — всё сразу:

- `make gate`: `0 failures`, `no offenses detected`,
  `детерминизм: источников случайности нет`;
- в выводе `make validate` дословно есть
  `✅ Все заявки из очереди покрыты`, `✅ Структура JSON корректна`,
  `✅ op_103: корректно выбран quickpay`, `✅ op_104: корректно выбран quickpay`,
  `✅ op_107: корректно выбран payflow`, `✅ op_108: корректно выбран quickpay`;
- итог: `❌ Ошибок:   0` и `⚠️  Предупр.: 0`, `EXIT=0`;
- `grep -rn "TODO(Ф1/R-11)" bin lib` ничего не находит.

Любое ненулевое число ошибок — FAIL. Ослаблять критерий и править валидатор организаторов
запрещено: его вердикт важнее нашего мнения о правильности.

---

## 6. Гейт зоны Вовы в Ф1

Выполняется раннером целиком, после PASS всех семи пакетов:

```
make gate && \
make no-random && \
( make validate ; echo "VALIDATE_EXIT=$?" ) && \
make determinism && \
grep -rn "TODO(Ф1/R-11)" bin lib ; echo "TODO_GREP_EXIT=$?" ; \
ls lib/routing/constraints/*.rb | wc -l
```

Признаки успеха:

1. `make gate` — `0 failures`, `no offenses detected`;
2. `make no-random` — `детерминизм: источников случайности нет`;
3. `make validate` — `❌ Ошибок:   0`, `⚠️  Предупр.: 0`, `VALIDATE_EXIT=0`,
   четыре эталонных кейса зелёные;
4. `make determinism` — `детерминизм: OK`;
5. `TODO_GREP_EXIT=1` (совпадений нет — TODO снят);
6. `ls lib/routing/constraints/*.rb | wc -l` = **10** (девять проверок + `base.rb`).

Гейт всей фазы Ф1 шире зоны Вовы: он же требует зелёных E-* и A-*. Но пункт 3 —
единственный, ради которого фаза существует, и он достигается уже пакетами V1–V7.

---

## 7. Что может сломаться молча

| # | Что | Почему молча | Чем ловится |
|---|---|---|---|
| 1 | `DailyLimit` встал раньше `AmountRange`, и op_103/payflow отсеян не той причиной | валидатор пишет это **предупреждением** (⚠️), а не ошибкой: `make validate` остаётся с `Ошибок: 0` | V6, спек-паритет пункт 7: 13 пар из `skip_reasons_expected` сверяются посимвольно; гейт требует `Предупр.: 0` |
| 2 | Изобретена своя формулировка `reason` | причины сверяются только на 13 известных парах, остальные семь причин никем снаружи не проверяются | V1–V6: `reason` берётся из `Reasons::SKIP`, спек реестра проверяет вхождение множеством |
| 3 | `details` без числа | JSON валиден, структура проходит, балл за объяснимость теряется на защите | Спек каждой проверки требует `details =~ /\d/`; `Routing::Details` — единственное место, где текст рождается |
| 4 | `nil` в лимите прочитан как `0` и всех отсекает | spacepayments перестаёт быть допустимым, но fallback всё равно подставляется — вывод внешне не меняется | V6 пункт 8: spacepayments проходит допуск для всех 10 операций; V2/V3: примеры «лимит `nil` → `nil`» |
| 5 | Сравнение маржи ушло во `Float`, и на других данных `1.1 + 0.1 > 1.2` даёт ложный отсев | на public-снапшоте маржа сравнивается один раз и всегда проходит — проверка не срабатывает никогда | V3: пример с `0.1 + 0.2` против `0.3`; правило `Rational(value.to_s)` |
| 6 | `RateLimit` начал отсеивать, хотя `requests_per_minute_limit` в снапшоте нет | появляется отсев на пустом месте, причина внешне выглядит настоящей | V5: три примера на «нет лимита / нет счётчика / нет метода → `nil`» |
| 7 | `RateLimit` взял минуту из текущего момента | два прогона дают разный вывод только на границе минуты — раз в N запусков | V5: `minute_key` из `created_at`, отдельный спек; `make no-random` (греп) + `make determinism` |
| 8 | `spacepayments` попал в каскад и перетянул безальтернативные заявки | валидатор считает его допустимым всегда (строка 31), ошибок не даст; упадут только эталонные кейсы — а они упадут и по другим причинам | V7, спек `planner_spec` пункт 3 и `route_spec` «ни одному решению не назначен spacepayments» |
| 9 | Порядок кандидатов зависит от порядка обхода хеша или от порядка ключей JSON | вывод валиден и стабилен на одной машине, разъезжается на другой версии Ruby | V7 пункты 5–6: сортировка по `priority` + tie-break по имени, спек на перемешанном входе; `make determinism` |
| 10 | `Planner` при пустом плане молча вернул `candidates == []` и `bin/route` записал `selected_provider: null` | JSON валиден, поле присутствует — структурная проверка валидатора проходит | V7: ветка fallback обязательна, `route_spec` проверяет непустой `selected_provider` у всех 10 решений |
| 11 | Спек паритета «подогнан» под нашу реализацию вместо файла организаторов | все зелёные, расхождение всплывает на test-очереди в час стопкода | V6: ожидания читаются **из** `reference_decisions.json` в рантайме спека, а не копируются в код; в брифе прямой запрет |
| 12 | `continue-on-error: true` остался в CI, и красный валидатор не валит билд | билд зелёный при 4 ошибках | V7 пункт 5 + пункт 3 гейта зоны |
| 13 | Правка `bin/route` разошлась с A-1 (`decisions_writer` Кирилла), и вывод собирается в двух местах | оба варианта дают валидный JSON, расхождение всплывает при первой правке формата | Противоречие C-3 объявлено заранее; V7 меняет только построение решения, отчёт не трогает; A-1 заменяет эту вставку целиком |

---

## 8. Порядок исполнения и риски

**Порядок:** V1 → (V2 ∥ V3 ∥ V4 ∥ V5, но кодеру по одному) → V6 → V7. Ни один пакет не
отдаётся до PASS предыдущего от раннера.

| Риск | Вероятность | Что делаем |
|---|---|---|
| IO-1/IO-2 Кирилла не готовы к моменту V7 | средняя | В брифе V7 заложен запасной путь: приватный `load_providers` в `bin/route` с пометкой `TODO(IO-1)`. Гейт зоны от этого не страдает |
| E-1 Максима не готов, `state` — заглушка | высокая | Восьми проверкам `state` не нужен, девятой (`RateLimit`) отсутствие данных не даёт отсеивать. Спеки вызывают проверки с `state = nil` |
| A-1 Кирилла перепишет `bin/route` и уронит валидатор | средняя | Предупредить Кирилла до старта V7 (C-3). После A-1 гейт зоны прогоняется повторно — та же команда §6 |
| Ф2 (CountShare) поменяет порядок каскада и разрушит op_107 | высокая, но **вне Ф1** | На порядке по `priority` payflow доходит до op_107 с остатком 51 200 ₽ дневного лимита. При CountShare этого не гарантируется; резервирование узких провайдеров — отдельная задача поздней фазы, в Ф1 не тащим |
| Кодер «поправит» ожидание в спеке паритета вместо кода | средняя | Прямой запрет в брифе V6 + требование читать ожидания из `reference_decisions.json` в рантайме |
| Три FAIL подряд по одному пакету | низкая | Стоп, эскалация человеку: почти наверняка противоречие в документах, а не баг. Критерий приёмки не ослабляем |

**Что в этой фазе не делаем, хотя руки тянутся:** стратегии (Ф2), перенормировку целей
(R-12, Ф2), слои, `Selector`, резервирование узких провайдеров, отчётные метрики. Пакет,
в котором появилось слово «стратегия» иначе как в комментарии-пометке, — вышел за фазу.
