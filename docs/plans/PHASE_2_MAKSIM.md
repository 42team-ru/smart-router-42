# Ф2 — Максим: интеграция ShareLedger + E-5 PendingResolver

## Context

Ф1 моей зоны закрыта (коммит `881426b`). После пуша Вовы+Кирилла в main
пайплайн собран end-to-end: `bin/route` → `Io::ProvidersLoader`/`QueueLoader`
→ `Routing::Planner`+Strategy → `Execution::Executor`+`State::Providers`+
OutcomeSource → `Reporting::DecisionsWriter`+`ReportBuilder`. Гейт: 326
examples, 0 failures. `make validate`: 29/0/0.

TASKS.md для меня в Ф2 — **одна** задача:
- **E-5 `PendingResolver` (2ч):** поздний статус-чек для `:expired`,
  компенсирующая корректировка «с текущего момента», прошлые решения
  не пересчитываются.

Дополнительно из `docs/plans/PHASE_2_VOVA.md §3.1` — прямая просьба Вовы к
моей зоне: **вложить `Routing::ShareLedger` внутрь `State::Providers` через
делегирование** (~1ч). Стратегии тогда читают счётчики долей через
`state.count_units`, а не через отдельный ledger. Вовин
`spec/support/shared/share_counters.rb` уже написан — переиспользую как
готовый контракт.

Сейчас в `bin/route:158` создаётся отдельный `Routing::ShareLedger.new`,
передаётся в `planner.plan(op, ledger)` для ранжирования, а после
`Executor#run` вручную вызывается `settle_share(ledger, outcome, op)`
(bin/route:119-126, 169). Двойная бухгалтерия долей (state тащит
in_progress/daily, ledger тащит доли), два разных объекта — уводить в
одно место через State.

## Границы зоны

- **Меняю:**
  - `lib/state/providers.rb` (интеграция @shares + `resolve_hold`)
  - `spec/state/providers_spec.rb` (расширяю)
  - `lib/execution/pending_resolver.rb` (новый)
  - `spec/execution/pending_resolver_spec.rb` (новый)
- **Требует лёгкой правки в чужом файле → отдельный коммит после `@Вова`
  / `@Кирилл`:**
  - `bin/route` (3 места: `pipeline[:ledger] = pipeline[:state].shares`,
    удалить `settle_share` определение и вызов). Без этого коммита
    ShareLedger-интеграция ничего не меняет наблюдаемо, но и ничего не
    ломает — двойная бухгалтерия остаётся, но валидатор зелёный.
- **Не трогаю:** `lib/routing/**`, `lib/execution/executor.rb`,
  `lib/execution/outcome_source/**`, `lib/domain/**`, `lib/io/**`,
  `lib/reporting/**`, `lib/config/**`, спеки чужих зон,
  `spec/support/shared/share_counters.rb` (Вовин файл, включаю через
  `include_examples`).

## Инварианты

- Никакого `rand`/`shuffle`/`sample`/`Time.now` в `lib/execution/`
  (греп по каталогу)
- ShareCounters read-методы возвращают `Integer`, никогда `nil`/`Float`
- `hold` продолжает сохранять запись для PendingResolver (**меняю
  семантику**: перенос из `@reservations` в новое `@held_reservations`,
  а не удаление).
- **Тест `spec/state/providers_spec.rb:85` «reserve после hold той же пары
  проходит» переписывается**, потому что новая семантика его инвертирует:
  `@shares.hold` в ledger reservation не снимает (это его контракт для
  «hold держит резерв», см. `share_ledger.rb:53-55`), а первая строка
  нового `State#reserve` — `@shares.reserve(provider, operation)` — упадёт
  на дубле. Значит поведение теперь: `reserve` той же пары после `hold`
  падает с `ArgumentError`; повторный маршрутинг expired-операции
  осуществляется через `resolve_hold(provider, op, :approved|:rejected)`.
  Это соответствует §7 ARCHITECTURE и договорённости «expired держит
  резерв до статус-чека».
- `E-5` критерий приёмки TASKS.md:73: «резерв освобождается, прошлые
  решения не пересчитываются» — PendingResolver не трогает attempts,
  не отменяет предыдущие commits, только вносит delta по текущей
  (op, provider) паре.
- reserve/commit/rollback/hold **возвращают `self`** для чейнинга (нужно
  для Вовиных shared examples: `subject.reserve(...).commit(...)`)

## Ключевые решения

### 1. State::Providers инкапсулирует ShareLedger

- Приватное поле `@shares = Routing::ShareLedger.new` (создаётся в
  `initialize`)
- Публичный `attr_reader :shares` — для bin/route (Planner получит
  через `state.shares`)
- 5 read-делегатов: `count_units`, `volume_units`, `total_count_units`,
  `total_volume_units`, `open_reservations` → однострочные вызовы `@shares`
- `reserve/commit/rollback/hold` — первая строка `@shares.same(provider,
  operation)`, дальше существующая логика in_progress/daily_approved.
  Возвращают `self`.
- Принимают провайдер как `Domain::Provider` **или** `String`
  (нормализация в private `provider_name` — Object → `#name`, String →
  сам). ShareLedger уже это умеет; State нужно расширить.

### 2. hold перестаёт стирать reservation

Сейчас:
```ruby
def hold(provider, operation)
  @reservations.delete([operation.operation_id, provider.name])
end
```

Станет:
```ruby
def hold(provider, operation)
  @shares.hold(provider, operation)
  key = [operation.operation_id, provider_name(provider)]
  amount = @reservations.delete(key)
  @held_reservations[key] = amount if amount
  self
end
```

`@shares.hold` уже держит свою reservation открытой
(`lib/routing/share_ledger.rb:53`), симметрично.

### 3. State::Providers#resolve_hold(provider, operation, actual)

Новый метод, вызывается PendingResolver'ом. `actual ∈ {:approved,
:rejected}`.

Псевдокод:
```ruby
def resolve_hold(provider, operation, actual)
  name = provider_name(provider)
  key = [operation.operation_id, name]
  amount = @held_reservations.delete(key) or
    raise ArgumentError, "no held reservation for (#{operation.operation_id}, #{name})"

  # Всегда: освобождаем in_progress (симметрично commit/rollback)
  @state_by_name[name][:in_progress_count] -= 1
  @state_by_name[name][:in_progress_amount] -= amount

  case actual
  when :approved
    @state_by_name[name][:daily_approved_amount] += operation.amount
    @shares.commit(provider, operation)  # доля остаётся у провайдера
  when :rejected
    @shares.rollback(provider, operation)  # доля возвращается
  else
    raise ArgumentError, "actual must be :approved or :rejected, got #{actual.inspect}"
  end
  self
end
```

### 4. Execution::PendingResolver — тонкая обёртка

```ruby
module Execution
  class PendingResolver
    ALLOWED_RESULTS = %i[approved rejected].freeze

    def resolve(state, provider, operation, actual)
      unless ALLOWED_RESULTS.include?(actual)
        raise ArgumentError, "actual must be :approved or :rejected, got #{actual.inspect}"
      end
      state.resolve_hold(provider, operation, actual)
    end
  end
end
```

Отдельный модуль — по §7 ARCH: «Execution::PendingResolver, отдельный
модуль». В Ф3 сюда прикрутится интеграция с внешним статус-чеком
(батчинг, логи, метрики). В Ф2 держим минимум.

### 5. bin/route изменение — отдельный коммит после уведомления

Три места:
- `bin/route:158` — `ledger: Routing::ShareLedger.new` → удалить эту
  строку, заменить на `ledger: pipeline_state.shares` (или инлайн)
- `bin/route:119-126` — удалить `settle_share` функцию
- `bin/route:169` — удалить вызов `settle_share(pipeline[:ledger],
  explained, operation)`

Порядок: сначала пушу State+PendingResolver коммит, потом ping Вове
и Кириллу в чате, потом bin/route коммит. При красном валидаторе после
bin/route — `git revert` и разбираемся, не подгоняя.

## Реиспользуемые куски

- `Routing::ShareLedger` — `lib/routing/share_ledger.rb` — использую как
  приватное поле State. Никаких правок.
- `spec/support/shared/share_counters.rb` — Вовин shared_examples
  'счётчики долей' — включу через `include_examples` в новую describe-
  секцию providers_spec.
- `spec/support/build_helpers.rb` — `build_provider`, `build_spacepayments`,
  `build_operation`. Уже используется в моих спеках.
- `spec/support/shared_state_invariants.rb` — существующий T-2, никаких
  правок; продолжает работать после интеграции.

## Порядок шагов

Каждый шаг заканчивается зелёным `make gate`. Не иду дальше, пока не
зелёно.

**Пре-шаг (руками пользователя, вне plan mode).** `git fetch && git pull`
из-под юзера (у моего runtime нет github creds; часть файлов может быть
root-owned от прошлых сессий — `chown -R mkass420:mkass420` перед pull).
После pull проверяем `make gate` + `make validate` — оба зелёные, иначе
стоп и разбираемся, что прилетело из main.

### Шаг 1 — интеграция ShareLedger в State::Providers (~1ч)

**Файл:** `lib/state/providers.rb`

1. `require_relative '../routing/share_ledger'` в шапке
2. `initialize`: добавить `@shares = Routing::ShareLedger.new`,
   `@held_reservations = {}`
3. `attr_reader :shares`
4. Read-делегаты: `count_units(p) = @shares.count_units(p)` и по
   аналогии volume_units / total_count_units / total_volume_units /
   open_reservations
5. Private `provider_name(p) = p.is_a?(String) ? p : p.name`
6. `reserve` — первой строкой `@shares.reserve(provider, operation)`,
   `name = provider_name(provider)`, дальше существующее. `self` в конце.
7. `commit` — первой строкой `@shares.commit(provider, operation)`,
   дальше существующее. `self` в конце.
8. `rollback` — первой строкой `@shares.rollback(provider, operation)`,
   дальше существующее. `self` в конце.
9. `hold` — первой строкой `@shares.hold(provider, operation)`, перенос
   `@reservations` → `@held_reservations`. `self` в конце.
10. Новый `resolve_hold(provider, operation, actual)` — по §3 выше.

**Файл:** `spec/state/providers_spec.rb`:

1. **Переписать существующий тест** `it 'reserve после hold той же пары
   проходит (для PendingResolver)'` (строки 85-90) на обратное поведение:
   ```ruby
   it 'reserve после hold той же пары падает (закрывать через resolve_hold)' do
     state.reserve(vipay, operation)
     state.hold(vipay, operation)

     expect { state.reserve(vipay, operation) }
       .to raise_error(ArgumentError, /reserve already held/)
   end
   ```

2. **Добавить в конец** новые describe-блоки:
   ```ruby
   describe 'роль ShareCounters (интеграция с Routing::ShareLedger)' do
     subject { described_class.new([build_provider('vipay'), build_spacepayments]) }
     require 'support/shared/share_counters'
     include_examples 'счётчики долей'
   end

   describe '#resolve_hold' do
     # :approved — in_progress откачен, daily_approved += amount, count_units держится +1
     # :rejected — in_progress откачен, daily не тронут, count_units обнулился
     # no held reservation — ArgumentError
     # actual ∉ {:approved,:rejected} — ArgumentError
     # non-interference: hold+resolve на op_1/vipay не задевает reserve+commit на op_2/payflow
   end
   ```

Гейт после шага. Ожидание: минимум 5 новых примеров пройдены
(shared 'счётчики долей' + resolve_hold сценарии), 1 переписан.

### Шаг 2 — E-5 PendingResolver (~1.5ч)

**Файл:** `lib/execution/pending_resolver.rb` (новый) — по §4 выше.

**Файл:** `spec/execution/pending_resolver_spec.rb` (новый):
- `#resolve(state, provider, op, :approved)` — state finishes в
  approved-подобном состоянии (in_progress откачен, daily_approved
  вырос, count_units держится +1)
- `#resolve(..., :rejected)` — state finishes в rejected-подобном
  (in_progress откачен, daily не тронут, count_units обнулился)
- `#resolve` с `:expired` — ArgumentError
- `#resolve` без предварительного hold — ArgumentError (пробрасывается
  из state.resolve_hold)
- **Invariance test:** делаем reserve+commit на op_2/payflow ДО
  hold на op_1/vipay ДО resolve_hold на op_1/vipay :approved. Проверяем:
  счётчики payflow не тронуты после resolve (критерий TASKS.md
  «прошлые решения не пересчитываются»)

Гейт после шага.

### Шаг 3 — bin/route правка (после уведомления команды, отдельный коммит)

**Файл:** `bin/route` — по §5 выше.

**Проверки:**
- `make gate` зелёный
- `make validate` — 29 passed / 0 errors
- `make determinism` — «детерминизм: OK»
- Ручная сверка `routing_decisions_test.json` до/после: `selected_provider`
  распределение остаётся 40/30/30 на публичной очереди при
  `--outcomes always_ok`

Если что-то поехало — `git revert` этого коммита, разбираемся в State-
части, не в bin/route.

## Файлы

**Меняю (1):**
- `lib/state/providers.rb`

**Создаю (2):**
- `lib/execution/pending_resolver.rb`
- `spec/execution/pending_resolver_spec.rb`

**Расширяю (1):**
- `spec/state/providers_spec.rb`

**После уведомления команды (1):**
- `bin/route`

## Верификация

**После Шага 1:** `make gate` — 326+ примеров (минимум +5 от shared
examples и resolve_hold), rubocop чист, no-random чист.

**После Шага 2:** `make gate` — плюс минимум 5 новых примеров в
pending_resolver_spec. `make validate` остаётся 29/0/0 (bin/route не
тронут).

**После Шага 3:** `make gate` + `make validate` + `make determinism` —
всё зелёное. Распределение по selected_provider на публичной очереди
остаётся идентичным.

## Открытые вопросы

- **bin/route touch** — жду `@Вова` / `@Кирилл` OK перед пушем Шага 3
  (пользователь подтвердил: Шаг 3 не пушу до его явного OK после
  уведомления команды). Если OK не приходит вовремя, Шаг 3 не делаю,
  задачу считаю сделанной «наполовину» (интеграция готова к
  использованию, но не задействована). Функционально пайплайн работает.
- **Ф3 CFG-1 у Кирилла в разработке.** Если он введёт зависимость на
  ShareLedger в конфиге, мои изменения нужно будет согласовать. Пока в
  `config/routing.yml` и `lib/config/*` ссылок на share нет — проверил.
