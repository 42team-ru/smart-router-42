# Ревью Ф1 (Максим) — свод решений

Не план реализации. Точка опоры для следующей сессии: что уже готово в репозитории,
какие интерфейсные решения приняты в этом обсуждении, где границы зоны.

## Контекст

Хакатон-движок роутинга выплат (`smart-router-42`, чистый Ruby). Зона Максима —
Execution & State: `lib/execution/`, `lib/state/`. Задачи Ф1 из `docs/TASKS.md`
(E-1..E-4, T-2), суммарно 7.0 ч. Ф0 (скелет и грeп-CI) закрыта его же руками
в предыдущей сессии; гейт локально зелёный (`71 examples, 0 failures`,
`22 files inspected, no offenses detected`, «источников случайности нет»).

## Состояние репозитория (проверено, не по памяти)

**Готово у Вовы (Ф0 P1) — не заглушки, а рабочие реализации:**
- `lib/routing/route_plan.rb:1` — валидация дублей/пересечения, `attempt_no_for`,
  `empty?`, `freeze` в конструкторе
- `lib/routing/attempt.rb:1` — валидация `decision` ∈ {selected, skipped},
  `KEY_ORDER`, `to_h` со сбросом nil кроме `ALWAYS_PRESENT`
- `lib/routing/violation.rb:14` — `#to_attempt(provider)` возвращает готовый Attempt
- `lib/domain/{provider,operation}.rb` — Data.define, иммутабельные
- `lib/routing/reasons.rb` — SKIP/SELECTED заморожены (10/5 строк)

**Заглушки в зоне Максима (Ф0 P1, ждут Ф1):**
- `lib/state/providers.rb:13` — `reserve/commit/rollback/hold` → NotImplementedError
- `lib/execution/executor.rb:10` — `#run(plan, operation, state)` → NotImplementedError
- `lib/execution/outcome_source/base.rb:9` — `#call(operation, provider, attempt_no)`
- `lib/execution/outcome.rb` — `Outcome = Data.define(:selected, :attempts, :result)` готов

**Заглушка Кирилла (Ф0 P4):** `bin/route:56` всем ставит `spacepayments`,
`make validate` → **ровно 4 ошибки** на эталонных кейсах (op_103/104/107/108).
Опорная цифра, к которой гейт Ф1 обязан прийти к 0.

**Блокеров для старта Максима нет:** единственная жёсткая зависимость (`RoutePlan`)
реализована. IO-1..3 (загрузчики Кирилла) для E-1..E-4 не критичны — в спеках
State поднимается с массивом `Domain::Provider`, собранным вручную из фикстуры.

## Принятые решения (это обсуждение)

### Интерфейсы

- `State::Providers.new(providers)` — Array<Domain::Provider>. Парсинг providers.json
  не пересекает границу зоны (IO-1 у Кирилла).
- `State::Providers#fallback → Domain::Provider`. Конструктор **райзит**, если
  spacepayments отсутствует в снапшоте — это же закрывает граничный случай §16
  «провайдер в очереди, но не в providers.json».
- `Executor.new(outcomes:)`; state приходит в `#run(plan, operation, state)`.
- Executor **собирает** массив attempts:
  - сначала skipped в порядке `plan.skipped` (через `violation.to_attempt(provider)`),
  - затем selected по каждой попытке в порядке каскада,
  - каскад исчерпан → `selected = plan.candidates.last`, `result: :rejected`
    (НЕ spacepayments — инвариант §7 «fallback по допуску, не по исходу»).
- `attempt_no` в `OutcomeSource#call` = 1-based позиция в каскаде этой операции
  (то самое, что возвращает `RoutePlan#attempt_no_for`; оно же в `attempts[].attempt_no`).
- `OutcomeSource::Deterministic.new(seed:, conversions: Hash{name=>Float})` —
  калиброванные конверсии инъекцией; IO-3 Кирилла в Ф2/Ф3 подаст свой хеш.
- `OutcomeSource::Scripted` — YAML `{op_id => {provider => outcome}}`
  (как в ARCHITECTURE.md §7).
- `OutcomeSource::AlwaysOk` / `AlwaysFail` — без параметров.

### units (счётчик доли)

**Не заводим в Ф1.** State работает только с `in_progress_count/amount` и
`daily_approved_amount`. `units` придёт в Ф2 вместе с Allocator (S-1/S-2 у Вовы).
Это минимально и честно: третий столбец таблицы §4 доклеится позже без ломания
интерфейса State (методы уже принимают operation, поле добавится внутрь).

### T-2 (shared examples §15)

5 инвариантов на **каждом** прогоне:
1. `attempts.map(&:provider).uniq.size == attempts.size` — без дублей
2. `state.in_progress_count == initial_in_progress` — всё освобождено
3. `skipped.map(&:reason).all? { |r| Constraints::REASONS.include?(r) }`
4. `selected_provider ∈ eligible_from_snapshot` — **логику переписать из
   `reference/scripts/validate_10.rb:25-51`**, не через наш REGISTRY
   (иначе замкнётся на себя; разъезд с валидатором T-2 не заметит).
5. `run_twice.map(&:to_json).uniq.size == 1` — воспроизводимость. Дублируем
   поверх Outcome, невзирая на существующий CLI-тест в `spec/bin/route_spec.rb`
   (разные уровни: unit vs sквозной).

### Граничные случаи §16 в Ф1

Из T-6 (F6) в Ф1 притаскиваем **только один**: «`null` в любом лимите — ограничения
нет». Без него `reserve(spacepayments)` упадёт первым же прогоном (у него все
`_limit` поля `null`). Остальные 8 остаются на F6.

## Порядок работ в Ф1

```
Ф0 (готово)
  │
  ├── E-1 (State::Providers)      ─┐
  ├── E-3 (OutcomeSource ×3)      ─┤ параллельно, разные файлы
  │                                │
  T-2 (shared examples) — пишется сквозным, подключается в каждый спек
  │                                │
  └── E-2 (Executor) ← E-1        ─┘
        │
        └── E-4 (fallback по допуску)
```

## Файлы, которые будут созданы/изменены в Ф1

**Без кода — только список.** Границы зоны: `lib/execution/`, `lib/state/`, `spec/`.
Ничего в `lib/routing/`, `lib/domain/`, `bin/`, `config/`.

| Файл | Операция | Таск | Замечание |
|---|---|---|---|
| `lib/state/providers.rb` | **изменение** (заглушка → реализация) | E-1 | конструктор принимает `Array<Domain::Provider>`, райзит без spacepayments |
| `lib/execution/executor.rb` | **изменение** (заглушка → реализация) | E-2, E-4 | `Executor.new(outcomes:)`, `#run(plan, operation, state)` |
| `lib/execution/outcome_source/deterministic.rb` | создание | E-3 | `.new(seed:, conversions: Hash)` |
| `lib/execution/outcome_source/scripted.rb` | создание | E-3 | YAML `{op_id => {provider => outcome}}` |
| `lib/execution/outcome_source/always_ok.rb` | создание | E-3 | без параметров |
| `lib/execution/outcome_source/always_fail.rb` | создание | E-3 | без параметров |
| `spec/support/shared_state_invariants.rb` | создание | T-2 | 5 инвариантов §15 как `shared_examples` |
| `spec/state/providers_spec.rb` | создание | E-1 | таблица исходов §4 + null-лимиты spacepayments |
| `spec/execution/executor_spec.rb` | создание | E-2, E-4 | 5 сценариев каскада §15 |
| `spec/execution/outcome_source/deterministic_spec.rb` | создание | E-3 | два прогона байт-в-байт |
| `spec/execution/outcome_source/scripted_spec.rb` | создание | E-3 | загрузка YAML, сверка (op_id, provider) |
| `spec/execution/outcome_source/always_spec.rb` | создание | E-3 | оба вырожденных источника |
| `spec/fixtures/outcomes/*.yml` | создание (2–3 файла) | E-3 | сценарии для Scripted и каскадных тестов |
| `spec/spec_helper.rb` | **изменение** | T-2 | `Dir[File.join(__dir__, 'support/**/*.rb')].each(&method(:require))` |

**Ничего не трогаем:** `lib/routing/**`, `lib/domain/**`, `bin/route`, `Makefile`,
`Gemfile`, `.rubocop.yml`, `scripts/*`, `.github/workflows/*`, `docs/**`,
`reference/**`, `spec/fixtures/contracts/*`, `spec/contracts/*`, `spec/bin/*`,
`spec/smoke_spec.rb`.

**Итого:** 2 изменения существующих + 12 новых файлов (7 кода, 5 спеков и фикстур).
Прикидка по TASKS.md — 7.0 ч.

## Что осталось решать по ходу (не блокеры)

- Формат ошибок State (Ruby-исключения vs Result-объект) — по месту.
- Наименование хелперов в spec (`build_provider(...)`, `stateful_state(...)`) —
  по месту, никого не блокирует.
- Схема YAML для Scripted — минимальная, документируется комментарием в файле.

## Шаги реализации

Шаги идут в порядке `E-1 ‖ E-3 → E-2 → E-4`. T-2 (shared examples) заводится
на первом же спеке E-1 и подключается во все последующие. Каждый шаг заканчивается
зелёным `make gate` — не идём дальше, пока не зелёно.

### Шаг 1 — E-1: `State::Providers` (2.0 ч)

**Файл:** `lib/state/providers.rb` (замена заглушки).

1. Конструктор `initialize(providers)` — принимает `Array<Domain::Provider>`.
   Строит `@by_name = providers.to_h { |p| [p.name, {…}] }` со снимком мутируемых
   полей: `in_progress_count`, `in_progress_amount`, `daily_approved_amount`,
   `available_requisites`. `Domain::Provider` остаётся иммутабельным — State держит
   свою параллельную таблицу.
2. Ищет `spacepayments` (или `fallback_provider` — имя фиксируется константой
   `FALLBACK_NAME = 'spacepayments'` в файле). Нет — `raise ArgumentError,
   "fallback provider #{FALLBACK_NAME} missing from snapshot"`.
3. `reserve(provider, operation)` — инкремент `in_progress_count += 1`,
   `in_progress_amount += operation.amount`. Пишет `@reservations[[op.id, name]]
   = operation.amount` для проверки идемпотентности (повторный reserve на ту же
   пару райзит).
4. `commit(provider, operation)` — `daily_approved_amount += operation.amount`,
   `release_capacity(name, op)`, снимает бронь.
5. `rollback(provider, operation)` — `release_capacity`, снимает бронь. Ничего
   не трогает у `daily_approved_amount`.
6. `hold(provider, operation)` — no-op, бронь и in_progress держатся; удаляет
   `@reservations` (иначе повторный проход упадёт на идемпотентности).
7. `fallback` — возвращает объект `Domain::Provider` для `FALLBACK_NAME`.
8. Публичные читалки: `in_progress_count(name)`, `daily_approved_amount(name)`,
   `snapshot(name)` — для инвариантов T-2.
9. `null` в лимите провайдера трактовать как «ограничения нет»: State
   не проверяет лимиты (это зона Constraints у Вовы), но `reserve` на spacepayments
   с `in_progress_count_limit = nil` не должен падать — счётчик просто растёт.

**Спек:** `spec/state/providers_spec.rb`.
- Таблица §4 воспроизводится: три сценария (approved / rejected / expired) →
  сверка `in_progress_count`, `in_progress_amount`, `daily_approved_amount`.
- `spacepayments` с null-лимитами: `reserve/commit/rollback/hold` не райзят.
- Отсутствие fallback в снапшоте → `ArgumentError` в конструкторе.
- Повторный `reserve` на пару (op, provider) → `ArgumentError` (идемпотентность).
- Подключить `include_examples 'state invariants'` (T-2, добавляется в этом шаге).

### Шаг 2 — E-3: `OutcomeSource ×3` (1.5 ч, параллельно с Шагом 1)

**Файлы:**
- `lib/execution/outcome_source/deterministic.rb`
- `lib/execution/outcome_source/scripted.rb`
- `lib/execution/outcome_source/always_ok.rb`
- `lib/execution/outcome_source/always_fail.rb`

Названий `rand/shuffle/sample/Time.now` нет ни в коде, ни в комментариях
(CI-грeп ловит).

1. **Deterministic** — `initialize(seed:, conversions:, reject_share: 500)`.
   `#call(operation, provider, attempt_no)` — SHA256 от `"#{seed}:#{op.id}:
   #{provider.name}:#{attempt_no}"`, взять `.to_i(16) % 10_000`, сравнить с
   `(conversions.fetch(provider.name) * 10_000).round`. Логика из ARCHITECTURE.md §7.
   `reject_share = 500` — 5% попыток идут в `:rejected`, остальные из непринятых —
   `:expired`. Значение выносится параметром, чтобы E-2/E-4 сценарии каскада могли
   его двигать.
2. **Scripted** — `initialize(script:)`, `script` — Hash `{op_id => {name => symbol}}`.
   Отдельный `Scripted.load(path)` — читает YAML, `YAML.safe_load(File.read(path),
   permitted_classes: [Symbol])`. `#call` возвращает `script.dig(op.id, provider.name)`;
   нет записи → `raise KeyError, "нет исхода для (#{op.id}, #{provider.name})"`.
3. **AlwaysOk** / **AlwaysFail** — `#call(*)` возвращает `:approved` / `:rejected`.
   Без конструктора, без состояния.

**Спеки:**
- `spec/execution/outcome_source/deterministic_spec.rb` — детерминизм двух прогонов
  побайтово (`Marshal.dump` двух Outcome равны); распределение по seed=42 на
  vipay(0.78) даёт `:approved` в ~78% из 1000 генераций (±3%). Формула тестируется
  на одной тройке значений «руками» — гарантия, что мы не поедем при смене
  реализации SHA256.
- `spec/execution/outcome_source/scripted_spec.rb` — загрузка YAML, промах ключа
  → KeyError.
- `spec/execution/outcome_source/always_spec.rb` — тривиально.
- **Фикстуры:** `spec/fixtures/outcomes/cascade_reject_then_ok.yml`,
  `spec/fixtures/outcomes/all_rejected.yml` — для сценариев E-2.

### Шаг 3 — E-2: `Executor` (1.5 ч, после Шага 1)

**Файл:** `lib/execution/executor.rb` (замена заглушки).

1. `initialize(outcomes:)` — только источник исходов.
2. `#run(plan, operation, state)` — псевдокод:
   ```
   attempts = plan.skipped.map { |p, v| v.to_attempt(p) }
   plan.candidates.each_with_index do |provider, i|
     attempt_no = i + 1
     state.reserve(provider, operation)
     result = outcomes.call(operation, provider, attempt_no)
     attempts << build_selected_attempt(provider, attempt_no, result)
     case result
     when :approved then state.commit(provider, operation);   return Outcome.new(...)
     when :expired  then state.hold(provider, operation);     return Outcome.new(..., :expired)
     when :rejected then state.rollback(provider, operation); next
     end
   end
   # каскад исчерпан
   return Outcome.new(selected: plan.candidates.last, attempts: attempts, result: :rejected)
   ```
3. `build_selected_attempt(provider, attempt_no, result)` строит `Routing::Attempt`
   с `decision: 'selected'`, `reason` = `first_eligible` для attempt_no==1, иначе
   `next_in_cascade`, `strategy: nil` (F1: стратегии нет — заполнит F2/F3),
   `details`: конкретное сравнение по operation.id и позиции в каскаде.
4. Case `plan.candidates.empty?` в этом шаге **не обрабатываем** — оставим на E-4.
   В Шаге 3 спек проверяет `raise` на пустом plan.

**Спек:** `spec/execution/executor_spec.rb` — 5 сценариев §15:
1. Первый успешен → одна попытка, `state.daily_approved(vipay)` вырос.
2. Отказ → следующий успешен → две selected-попытки, rollback у первого.
3. Таймаут → одна попытка, `state.in_progress(vipay)` не откачен.
4. Каскад исчерпан → `selected == candidates.last`, `result == :rejected`;
   spacepayments **не** в attempts.
5. Пустой plan → `raise` (E-4 в Шаге 4 заменит на fallback).

Подключить shared examples T-2 к каждому спеку.

### Шаг 4 — E-4: fallback по допуску (0.5 ч)

**Файл:** `lib/execution/executor.rb` (доработка).

1. В начале `#run`: если `plan.empty?` → `provider = state.fallback`; `reserve/call/
   commit-hold-rollback` как обычная одиночная попытка; `attempts` = [attempt для
   fallback с `reason: 'fallback_no_eligible_provider'`].
2. Никаких других мест fallback не вставляется. spacepayments не подхватывает
   каскад после отказов — это ловится 4-м сценарием Шага 3.

**Спек:** пятый сценарий §15 добавляется в `executor_spec.rb`:
- «Никто не прошёл допуск» → `selected == spacepayments`, `attempts.size == 1`,
  `attempts[0].reason == 'fallback_no_eligible_provider'`.
- Регрессия для 4-го сценария из Шага 3 остаётся зелёной.

### Шаг 5 — T-2: shared examples §15 (1.5 ч, сквозным)

**Файл:** `spec/support/shared_state_invariants.rb`.

1. Создать `RSpec.shared_examples 'state invariants'` с 5 проверками §15
   (см. секцию «T-2» выше). Каждая ожидает от контекста `let(:outcome)` и
   `let(:state)` (или `let(:initial_state_snapshot)`).
2. Пятый инвариант — переписать `eligible_providers(operation, providers)` из
   `reference/scripts/validate_10.rb:25-51` в хелпер спека. Комментарий над
   хелпером ссылается на строки валидатора.
3. `spec/spec_helper.rb` — добавить `Dir[File.join(__dir__, 'support/**/*.rb')].
   sort.each { require _1 }` до `RSpec.configure`.
4. Подключить `include_examples 'state invariants'` во все спеки E-1/E-2/E-4.
5. Пятый инвариант (воспроизводимость) — прогон одного и того же входа дважды
   через `Marshal.load(Marshal.dump(state))` и сверка `Outcome#to_h` через
   `JSON.generate` побайтово.

## Верификация

**После каждого шага:**
```
make gate
```
0 failures, `no offenses detected`, «источников случайности нет». Не переходим
к следующему шагу, пока не зелёно.

**После Шага 4 (E-4 закрыл fallback):** запускаем валидатор с настоящим Executor
поверх временной обвязки в спеке — не через `bin/route` (это зона Кирилла: A-1,
A-2). Проверка `Executor + State` на public-очереди делается через
`spec/integration/end_to_end_spec.rb` (создаётся в Шаге 4 как контрольная точка):
берёт `reference/data/operations_queue_10.json`, гоняет каждую операцию через
Constraints Вовы → RoutePlan → Executor(AlwaysOk) → сверяет `selected_provider`
с `reference/data/reference_decisions.json → eligible_providers[op_id]` и с
`deterministic_cases`. **Ожидание:** все 10 операций отдают провайдера из eligible;
op_103/104/107/108 — точный `required_provider`. Если Вовин Constraints ещё не
готов — пропускается через `pending`, но факт наличия проверки — часть гейта Ф1.

**Сводный гейт Ф1** (не наша единолично зона — общий с командой):
```
make gate         # наши инварианты и линтер
make validate     # валидатор организаторов, 0 ошибок
```
`make validate` → 0 ошибок = Ф1 закрыта.

**Ручная проверка воспроизводимости** отдельно от `make gate`:
```
make determinism
```
`диff -q /tmp/run1.json /tmp/run2.json` → одинаковые байты.

**Проверка на источники случайности:**
```
make no-random
```
«источников случайности нет».

## Ссылки

- `docs/TASKS.md:57-95` — таблица Ф1 и роли
- `docs/OWNERSHIP.md:67-83` — зона Максима, «три вещи, ломающие всё молча»
- `docs/ARCHITECTURE.md:97-152` — §4 State и таблица исходов
- `docs/ARCHITECTURE.md:222-292` — §7 Каскад и исходы, OutcomeSource
- `docs/ARCHITECTURE.md:540-566` — §15 Тесты и инварианты
- `reference/scripts/validate_10.rb:25-51` — эталонная логика eligible_providers
