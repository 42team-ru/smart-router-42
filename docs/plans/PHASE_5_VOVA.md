# Ф5 — Доказательства качества. План работ Вовы (X-4, X-5)

Источники: `AGENTS.md` → `docs/SCOPE.md` → `docs/ARCHITECTURE.md` (§7, §10, §12 «Блок
`benchmark`») → `docs/TASKS.md` (раздел «Ф5», включая «Три оговорки к X-4/X-5») →
`docs/OWNERSHIP.md` (правка 2026-09-04) → `docs/RESEARCH.md` (идея 5) →
`docs/plans/PHASE_4_VOVA.md` → `reference/scripts/validate_10.rb`.
Все числа получены прогонами и прототипом при планировании, не оценены.

**Зона плана.** X-4 и X-5 целиком. X-6, A-7, A-8 — Кирилл, в план не входят; что именно
X-4 обязан ему отдать и когда — §6. Контракт `offline_bound` замораживается **первым
пакетом (W1)** и до начала A-7, как требует `TASKS.md`.

**Гейт фазы:** `make gate` И `make validate` зелёные плюс зональный гейт §7.

---

## 0. Фактическое состояние репозитория (проверено запуском)

`make gate` — 478 примеров, 0 падений; rubocop 124 файла, 0 замечаний; `make no-random`
чист. `make validate` — `✅ Пройдено: 29 / ❌ Ошибок: 0 / ⚠️ Предупр.: 0`.

Дефолтный прогон (`config/routing.yml`: `count_share`, `layers: []`, `deterministic`,
`seed: 42`, `calibrate_from_history: true`; калибровка даёт vipay 0.780, quickpay 0.675,
payflow 0.474):

| операция | сумма | банк | допустимые по снапшоту | наш выбор | исход |
|---|---|---|---|---|---|
| op_101 | 15 000 | sberbank | vipay, payflow, quickpay | vipay | approved |
| op_102 | 48 000 | alfa | payflow, quickpay | payflow | approved |
| op_103 | 150 000 | sberbank | **quickpay** | quickpay | expired |
| op_104 | 3 000 | gazprombank | **quickpay** | quickpay | expired |
| op_105 | 25 000 | tinkoff | vipay, quickpay | vipay | approved |
| op_106 | 52 000 | sberbank | vipay, quickpay | vipay | approved |
| op_107 | 800 | sberbank | **payflow** | payflow | approved |
| op_108 | 42 000 | raiffeisen | **quickpay** | quickpay | approved |
| op_109 | 10 000 | vtb | vipay, quickpay | vipay | approved |
| op_110 | 40 000 | alfa | payflow, quickpay | payflow | approved |

Итог: vipay 4, payflow 3, quickpay 3, spacepayments 0; 8 `approved`, 2 `expired`,
0 `rejected`; каждая операция закрыта первой же попыткой каскада.

Числа отчёта, на которые опирается фаза:

- `distribution`: 40.0 / 30.0 / 30.0 при `achievable_pct` 40.0 / 30.0 / 30.0 и
  `deviation_pp` **0.0 у всех троих** (отклонение меряется от достижимой доли);
- `projected_daily_utilization.payflow`: `used 2 988 800`, `limit 3 000 000`, 99.6 %;
- `benchmark` — заглушка `lib/reporting/report_builder.rb:148`, три поля со значением
  `null`; в `routing_report_test.json` это строка 121.

Точки врезки:

- `lib/reporting/report_builder.rb:87` — `'benchmark' => benchmark`, и `:148` — сам метод
  заглушки. Это единственное место, куда попадает блок.
- `bin/route:299` — `build_pairs` возвращает пары; `bin/route:300` — `write_outputs`.
  Между ними и садится оракул: все решения уже приняты, файлы ещё не записаны.
- `bin/route:127` `build_outcome_source` — **единственная** точка построения источника
  исходов. Оракул обязан получить тот же объект, а не построить свой.
- `lib/execution/executor.rb:36` `run_cascade` — нумерует попытки `i + 1` сам; оракулу
  не нужно нумеровать вручную, если он исполняет каскад тем же `Executor`.
- `lib/state/providers.rb:38` — конструктор копирует мутируемые поля в собственную
  таблицу и не трогает `Domain::Provider` (он `Data`, заморожен). Поэтому
  `State::Providers.new(providers)` — это точный откат к исходному снапшоту, и на этом
  строится вся пересимуляция.
- `lib/routing/constraints.rb:22` — `check(provider, operation, state = nil)`;
  `lib/routing/constraints/daily_limit.rb:26` читает `state.daily_approved_amount`, если
  состояние отвечает. Допуск в контрфактуале считается по **живому** состоянию оракула.

Находка `PHASE_4_VOVA.md` §0.2 (дневной лимит по снапшоту) закрыта: payflow набирает
2 988 800 при лимите 3 000 000, четвёртой заявки не берёт. Фаза Ф5 на это опирается.

---

## 1. Противоречия в постановке (называю, не решаю молча)

### C-1. Форма блока в коде не совпадает с замороженным контрактом

`lib/reporting/report_builder.rb:148` отдаёт плоские `offline_optimum_deviation_pp` /
`ours_deviation_pp` / `competitive_ratio`. `ARCHITECTURE.md` §12 задаёт вложенный блок с
`offline_bound` / `our_online_result` / `competitive_ratio` / `note`. `RESEARCH.md`
(идея 5) использует третье имя — `offline_optimum`.

Приоритет документов (`AGENTS.md`): `SCOPE` → `ARCHITECTURE` → `TASKS` → остальное.
`TASKS.md`, оговорка 2, решает спор по имени явно в пользу `offline_bound`. **Побеждает
`ARCHITECTURE.md` §12; код и `RESEARCH.md` приводятся к нему.** Итоговая форма — §3.1,
правка кода — W1, пометка в `RESEARCH.md` — W6. Это не обсуждается кодером.

### C-2. От какой базы меряется отклонение в `benchmark` — от цели или от достижимой доли

В отчёте уже есть `distribution.*.deviation_pp`, и он меряется **от достижимой** доли
(`Distributions.achievable_pct`, комментарий на `lib/reporting/distributions.rb:66`).
На публичной очереди он равен 0.0 у всех. Пример в `ARCHITECTURE.md` §12 показывает
`max_deviation_pp: 5.0` — а 5.0 получается только от **паспортной** цели 40/35/25
(payflow 30 против 35, quickpay 30 против 25).

**Вариант A (принят планом).** `benchmark` меряет отклонение от паспортной цели
`traffic_percentage`. На публичной очереди наш результат — 5.0, эталон — 5.0, отношение
1.0, то есть ровно числа из `ARCHITECTURE.md` §12 и `RESEARCH.md`. Блок отвечает на
вопрос «мог ли вообще кто-нибудь выполнить паспортные цели лучше нас» — и отвечает
«нет, 5 п.п. неустранимы». Цена: в одном файле стоят два разных «отклонения» (0.0 в
`distribution`, 5.0 в `benchmark`), и `note` **обязана** назвать базу каждого.

**Вариант B.** Мерить от достижимой доли. Тогда эталон 0.0, наш результат 0.0, отношение
вырождается в конвенцию 0/0, и блок не несёт информации: он не может отличить хороший
прогон от плохого, пока мы попадаем в достижимое. Плюс расходится с обоими документами.

Принят A. Замена базы — решение человека, не кодера; она меняет все числа §3.

### C-3. Что считать «доставленной» операцией

`expired` по ответу Q&A (`ARCHITECTURE.md` §7) считается **условно успешным**: резерв
держится, каскад не продолжается. В нашем прогоне 8 `approved` + 2 `expired`. Пример в
`ARCHITECTURE.md` §12 показывает `delivered: 10` на очереди из 10 заявок — то есть
`expired` в `delivered` **входит**. Решение: `delivered` = число операций, чей итог не
`rejected`. Считать только `approved` (получилось бы 8) — значит противоречить и Q&A, и
замороженному примеру. Зафиксировано в §3.2 и проверяется спеком.

### C-4. `competitive_ratio` при нулевом знаменателе

Отношение `ours / bound` для минимизируемой величины не определено, когда эталон достиг
нуля. На публичной очереди этого не происходит (5.0 / 5.0), но на другой очереди —
может. Конвенция, замораживается вместе с блоком:

- `bound == 0` и `ours == 0` → `1.0` (совпали с эталоном);
- `bound == 0` и `ours > 0` → `null`, и `note` обязана назвать абсолютный разрыв в п.п.;
- пустая очередь → весь блок `null` с `note` «очередь пуста».

`X-5` требует, чтобы `competitive_ratio` «присутствовал и был объяснён»: ключ присутствует
всегда, а его отсутствующее значение объяснено текстом. Обратная альтернатива — считать
отношение по `delivered` (всегда определено, но расходится с примером §12) — отвергнута.

### C-5. `lib/reporting/` — зона Кирилла

`OWNERSHIP.md` (правка 2026-09-04) вводит именное исключение: «файл эталона и блок
`benchmark` в отчёте пишет Вова, всё остальное в `lib/reporting/` остаётся за Кириллом».
Поэтому правка `report_builder.rb` разрешена, но обязана быть точечной: метод `benchmark`
и один необязательный kwarg. Всё остальное в файле не трогается. Уведомление Кириллу до
мержа W1 — обязательно, потому что W1 меняет форму блока, на который он завязывает A-7.

### C-6. Бюджет 5.0 ч против объёма

`TASKS.md`: X-4 4.0 + X-5 1.0 = 5.0 ч. План весит ровно 5.0 (§4) при условии, что оракул
переиспользует `Execution::Executor` и `Routing::Constraints`, а не пишет вторую модель
исполнения. Собственная модель исходов внутри оракула — прямой путь к тому, чтобы эталон
считался в другой вселенной (§8), и запрещена планом.

---

## 2. Точки стыка с чужими зонами

| Файл | Владелец | Что делаем | Как согласовано |
|---|---|---|---|
| `lib/reporting/report_builder.rb` | Кирилл, кроме `benchmark` | новая форма блока + kwarg `benchmark:` с дефолтом `nil` | именное исключение `OWNERSHIP.md`; остальные секции отчёта не трогаются |
| `spec/reporting/report_builder_spec.rb:166` | Кирилл | правится **один** пример — тот, что фиксирует заглушку | остальные примеры файла остаются дословно |
| `spec/contracts/fixtures_spec.rb:229`, `spec/fixtures/contracts/report.json:37` | Вова (заморозка C-2 из Ф0) | форма блока приводится к §3.1 | это наш собственный контракт, разморозка законна и делается один раз, в W1 |
| `lib/execution/*`, `lib/state/*` | Максим | **не трогаем ни строки** | оракул только вызывает `Executor#run` и `State::Providers.new` — публичные точки, уже используемые `bin/route` |
| `lib/routing/*` | Вова | **не трогаем в Ф5** | оракул живёт вне решающего пути и в `lib/routing` не имеет права появляться (§3.5) |
| `lib/io/*`, `lib/config/*` | Кирилл | не трогаем | новых ключей конфига фаза не заводит: seed и конверсии оракул берёт у уже построенного источника исходов |
| `scripts/check_determinism.sh` | Максим (C-4 из Ф0) | +1 каталог `lib/offline` в `DIRS` | форма проверки не меняется, добавляется имя каталога |
| `bin/route` | общий | +1 вызов между `build_pairs` и `write_outputs` | порядок вызовов фиксирует инвариант «после решений, до записи» |

Новый каталог `lib/offline/` — зона Вовы целиком, конфликтов нет. Имя `Offline`, а не
`Benchmark`: `Benchmark` занят стандартной библиотекой Ruby, и одноимённый модуль верхнего
уровня рано или поздно даст неотлаживаемое переопределение константы.

---

## 3. Что замораживается в этой фазе

### 3.1 Контракт блока `benchmark` — дословно

Это контракт для A-7 Кирилла и для демо. После W1 форма не меняется до конца хакатона.

```json
"benchmark": {
  "offline_bound": {"max_deviation_pp": 5.0, "delivered": 10},
  "our_online_result": {"max_deviation_pp": 5.0, "delivered": 10},
  "competitive_ratio": 1.0,
  "note": "эталон эвристический: жадный старт и локальные улучшения с учётом порядка очереди, не доказанный оптимум; отклонение меряется от паспортных целей 40/35/25, а не от достижимых, поэтому не совпадает с distribution.deviation_pp; контрфактуалы посчитаны нашим симулятором (seed 42), а не генератором организаторов"
}
```

Типы и правила, проверяемые спеком:

| поле | тип | правило |
|---|---|---|
| `offline_bound.max_deviation_pp` | Float, 1 знак, ≥ 0 | максимум по всем провайдерам снапшота (включая spacepayments с целью 0) |
| `offline_bound.delivered` | Integer, 0…N | итог не `rejected` |
| `our_online_result.*` | те же типы | считается **тем же** кодом, что и эталон (§3.2) |
| `competitive_ratio` | Float, 2 знака, или `null` | `ours / bound`, конвенции C-4 |
| `note` | String, непустая, содержит цифры | база отклонения, характер эталона, источник исходов |

Ключи, порядок ключей и вложенность — ровно как выше. Пустая очередь: `offline_bound` и
`our_online_result` равны `null`, `competitive_ratio` `null`, `note` — «очередь пуста,
эталон не считался». Ключи присутствуют всегда.

### 3.2 Определение метрик (одно на оба блока)

Обе половины блока считает **один** модуль `Offline::Objective`. Два независимых расчёта
для «нас» и для «эталона» запрещены: расхождение баз — самая дорогая тихая ошибка фазы.

```
counts[p]        число операций, у которых итоговый selected_provider == p
total            размер очереди
target_bp[p]     provider.traffic_percentage * 100          (spacepayments: 0)
deviation_num[p] |counts[p] * 10_000 − target_bp[p] * total|      ← целое, сравнимое
max_deviation_num = max по всем провайдерам снапшота
delivered        число операций с итогом != :rejected      (approved и expired)
```

`deviation_num` — целое, потому что `total` одинаков для всех сравниваемых планов;
делить не нужно ни разу. Во float переводится **только на границе JSON**:

```
max_deviation_pp = Rational(max_deviation_num, total * 100).to_f.round(1)
competitive_ratio = Rational(ours_num, bound_num).to_f.round(2)
```

Проверка на публичной очереди (посчитано): vipay `|4·10000 − 4000·10| = 0`, payflow
`|3·10000 − 3500·10| = 5000`, quickpay `|3·10000 − 2500·10| = 5000`, spacepayments 0 →
`max_deviation_num = 5000` → `5.0 п.п.`, `delivered = 10`.

Целевая функция оракула — **лексикографический кортеж** `[−delivered, max_deviation_num]`:
сначала максимум доставленных, потом минимум отклонения. Обоснование: доля провайдера в
недоставленных деньгах смысла не имеет. Сравнение — сравнением массивов целых, строгое
улучшение и только оно.

### 3.3 Контракт оракула

```ruby
Offline::Simulation.new(providers:, outcomes:, fallback_provider: 'spacepayments')
#run(operations, assignment) -> Offline::Metrics
# assignment: Array<String|nil>, длина == operations.size, индекс = позиция в очереди

Offline::Oracle.new(providers:, operations:, outcomes:)
#call(online_assignment) -> Offline::Bound(metrics:, assignment:, passes:, simulations:)

Offline::Objective.metrics(counts:, delivered:, providers:, total:) -> Offline::Metrics
Offline::Metrics = Data.define(:max_deviation_num, :delivered, :total, :counts)
#max_deviation_pp -> Float
#key -> [Integer, Integer]                        # [-delivered, max_deviation_num]

Offline::Objective.deviations_pp(counts:, providers:, total:) -> {name => Float}  # для A-7
```

Инварианты, нарушение любого делает эталон неверным:

1. **Никакого переноса исходов.** Контрфактуал считается **пересимуляцией** через
   `Execution::Executor` с тем же `OutcomeSource`. Кэш «исход по (operation_id, provider)»
   запрещён: `attempt_no` входит в ключ хеша (`ARCHITECTURE.md` §7), и провайдер, стоящий
   в каскаде вторым, обязан получить исход попытки № 2. На реальных данных это видно:
   `(op_101, vipay, 1) = approved`, `(op_101, vipay, 2) = rejected` — перепутанный номер
   даёт противоположный результат.
2. **Свежее состояние на каждую симуляцию.** `State::Providers.new(providers)` — полный
   откат к исходному снапшоту. Боевое состояние прогона оракулу не передаётся вообще.
3. **Порядок очереди не меняется.** Операции обрабатываются в порядке очереди; оракул
   переставляет только назначения, не заявки. Это и снимает риск «исходы из другой
   вселенной» на уровне конструкции, а не аккуратности.
4. **Каскад достраивается детерминированно.** Каскад операции =
   `[выбранный, если допустим по живому состоянию] + остальные допустимые по возрастанию
   имени`. Если выбранный недопустим — он просто выпадает. Пустой каскад — fallback тем
   же `Executor#run_fallback`, что и в бою.
5. **Эталон не хуже нас по построению.** Первая стартовая точка поиска — вектор первых
   кандидатов **нашего** онлайн-прогона. Отсюда `competitive_ratio ≥ 1.0` всегда, а не по
   удаче; иначе «эталон» может оказаться хуже онлайна, и блок начнёт врать в нашу пользу.
6. **Ноль влияния на решения.** Оракул вызывается один раз, после того как все пары
   посчитаны, и до записи файлов. `lib/routing/**` и `lib/execution/**` не содержат ни
   одной ссылки на `Offline::` — проверяется грепом в спеке.

### 3.4 Алгоритм (идея 5: жадный поиск + локальные улучшения)

```
1. seed_a = вектор первых кандидатов нашего онлайн-прогона
2. seed_b = жадный проход:
     для каждой операции по порядку, среди допустимых по ЖИВОМУ состоянию,
     минимизируем [доставит ли попытка №1 (0/1), max_deviation_num на префиксе, имя];
     исход попытки берётся ЧИСТЫМ вызовом outcomes.call(op, p, 1) — состояние не мутируется;
     выбор исполняется одним прогоном Executor, состояние двигается вперёд
3. инкумбент = лучший из seed_a, seed_b по кортежу §3.2
4. локальный поиск, не более MAX_PASSES = 3 проходов:
     операции в порядке очереди; альтернативы — допустимые по ИСХОДНОМУ снапшоту,
     кроме текущей, по возрастанию имени;
     каждая альтернатива = полная пересимуляция очереди;
     принимается только строгое улучшение кортежа (first improvement);
     проход без улучшений завершает поиск
```

Замер прототипом при планировании (тот же `Executor`, те же данные):

| очередь | итог | симуляций | время |
|---|---|---|---|
| `operations_queue_10.json`, 10 операций | `delivered 10`, `max_deviation 5.0 п.п.` | 9 | < 0.01 с |
| синтетическая 100 операций | `delivered 97`, `max_deviation 26.0 п.п.` | 71 | **0.14 с** |

Критерий X-4 «считается за секунды на 100 операциях» выполняется с запасом в два порядка.
Константы `MAX_PASSES = 3` и `LOCAL_SEARCH_MAX_OPS = 500` (свыше — только жадный старт, и
`note` это сообщает) фиксируются в коде, параметрами конфига не становятся.

Почему это `bound`, а не оптимум: одобрение съедает `daily_amount_limit` и `in_progress`,
меняя допуск последующим заявкам, поэтому назначения не независимы и жадный поиск с
локальными улучшениями даёт оценку, а не доказанный минимум. На публичной очереди 5.0 п.п.
доказуемо неустранимы и без оракула (quickpay безальтернативен на op_103, op_104, op_108 →
его доля ≥ 30 % при цели 25 %; payflow не может взять четвёртую заявку: минимальная
четвёрка 800 + 15 000 + 40 000 + 48 000 = 103 800 > headroom 100 000), но это свойство
данных, а не алгоритма. Имя поля остаётся `offline_bound`.

### 3.5 Детерминизм

- Обхода хешей в решающих местах нет: подсчёт распределения идёт по массиву `providers`,
  альтернативы — по отсортированным именам, операции — по порядку очереди.
- Никаких `rand`/`shuffle`/`sample`/`Time.now`: `scripts/check_determinism.sh` получает
  `lib/offline` в `DIRS` (W6).
- Float появляется дважды и только на границе JSON (`max_deviation_pp`,
  `competitive_ratio`); сравнения планов — целочисленные.
- Оракул считает один раз и не зависит от порядка вызова относительно других секций
  отчёта: `make determinism` обязан остаться зелёным, а два прогона — побайтово равными.
- Фикстура очереди на 100 операций **коммитится файлом** и порождается без случайности:
  десять копий публичной очереди с идентификаторами `op_1001…op_1100`, `created_at` не
  меняется. Генератор с `rand` в репозитории запрещён — цифры демо обязаны воспроизводиться.

---

## 4. Пакеты работ

| ID | Пакет | TASKS | Зависит | Проверяется одной командой |
|---|---|---|---|---|
| W1 | Заморозка формы блока `benchmark`: вложенный контракт со значениями `null`, фикстура, два спека | X-5 | — | `make gate` + `make validate` + пустой `diff` decisions |
| W2 | `Offline::Objective` и `Offline::Metrics`: отклонения от цели, `delivered`, кортеж | X-4 | W1 | `bundle exec rspec spec/offline/objective_spec.rb` |
| W3 | `Offline::Simulation`: пересимуляция назначения на свежем состоянии через `Executor` | X-4 | W2 | `bundle exec rspec spec/offline/simulation_spec.rb` |
| W4 | `Offline::Oracle`: жадный старт, локальный поиск, засев нашим планом, фикстура на 100 операций | X-4 | W3 | `bundle exec rspec spec/offline/oracle_spec.rb` |
| W5 | Врезка в `bin/route`, реальные числа в блоке, `note` | X-5 | W4 | `make validate` + сверка блока с эталонным JSON |
| W6 | Гейт зоны: `check_determinism.sh`, замер времени, правка `RESEARCH.md` идея 5, отметка контракта для Кирилла | — | W5 | §7 целиком |

```
W1 ── W2 ── W3 ── W4 ── W5 ── W6
 └─ разблокирует A-7 Кирилла сразу после PASS
```

Часы: W1 0.5, W2 0.5, W3 1.0, W4 1.5, W5 1.0, W6 0.5 — **5.0 ч**, ровно бюджет
`TASKS.md` (4.0 + 1.0).

**Что снимается при нехватке времени, в этом порядке:** сначала локальный поиск в W4
(остаётся жадный старт плюс засев нашим планом — эталон остаётся корректной нижней
оценкой, но более слабой; `note` обязана это сказать); затем фикстура на 100 операций
(тогда критерий скорости не проверен, и это записывается риском). W1 не снимается ни при
каких обстоятельствах: без него A-7 Кирилла стоит.

---

## 5. Брифы кодеру

Каждый бриф самодостаточен: кодер плана не видел. Один бриф — один заход.

---

### БРИФ W1 — заморозка формы блока `benchmark`

**Контекст.** `lib/reporting/report_builder.rb:148` отдаёт устаревшую плоскую форму блока
(`offline_optimum_deviation_pp` / `ours_deviation_pp` / `competitive_ratio`, все `null`).
Замороженный контракт проекта — вложенная форма из `docs/ARCHITECTURE.md` §12. Расхождение
блокирует задачу A-7 другого разработчика, поэтому форма фиксируется отдельным пакетом,
раньше самого расчёта. **Значения в этом пакете остаются `null`: считать эталон здесь
не нужно.**

**Файлы.**

1. `lib/reporting/report_builder.rb`:
   - метод `benchmark` возвращает вложенную форму:
     `{'offline_bound' => nil, 'our_online_result' => nil, 'competitive_ratio' => nil,
     'note' => 'эталон не считался'}`;
   - `self.build` и `self.write` получают необязательный kwarg `benchmark: nil`; когда он
     передан — блок берётся из него целиком, без правки и без валидации; когда `nil` —
     возвращается заглушка выше;
   - порядок ключей в отчёте не меняется, `'benchmark'` остаётся между `'fallback'` и
     `'deviation_causes'` (строка 87). Больше в файле не меняется ничего.
2. `spec/fixtures/contracts/report.json:37` — блок приводится к целевой форме со всеми
   четырьмя ключами и заполненными значениями-образцами:
   `{"offline_bound": {"max_deviation_pp": 5.0, "delivered": 10}, "our_online_result":
   {"max_deviation_pp": 5.0, "delivered": 10}, "competitive_ratio": 1.0, "note": "..."}`.
   Фикстура — это образец формата, в ней значения не `null`.
3. `spec/contracts/fixtures_spec.rb:229` — пример «benchmark присутствует и допускает null»
   заменяется на проверку формы: четыре ключа именно с этими именами; `offline_bound` и
   `our_online_result` — либо `nil`, либо хеш с ключами `max_deviation_pp` (Float) и
   `delivered` (Integer); `competitive_ratio` — `nil` или Float; `note` — непустая строка,
   содержащая цифру.
4. `spec/reporting/report_builder_spec.rb:166` — правится **ровно один** пример, тот, что
   фиксирует старую заглушку. Остальные примеры файла не трогаются.

**Инварианты.**

- `routing_decisions_test.json` побайтово не меняется.
- В `routing_report_test.json` меняется **только** блок `benchmark`; все остальные секции
  дают тот же текст.
- Никакой логики расчёта в этом пакете не появляется.

**Спеки, которые должны появиться.**

1. `ReportBuilder.build` без kwarg — блок с четырьмя ключами, значения `null`, `note`
   непустая.
2. `ReportBuilder.build(..., benchmark: {...})` — переданный хеш попадает в отчёт как есть.
3. Форма из фикстуры контракта проходит проверку `spec/contracts/fixtures_spec.rb`.

**Критерий приёмки.** `make gate` — 0 падений, rubocop 0 замечаний; `make validate` —
`❌ Ошибок: 0`; `diff` `out/routing_decisions_test.json` с прогоном до пакета — **пуст**;
`ruby -rjson -e 'p JSON.parse(File.read("out/routing_report_test.json"))["benchmark"].keys'`
печатает `["offline_bound", "our_online_result", "competitive_ratio", "note"]`.

---

### БРИФ W2 — `Offline::Objective`: метрики качества маршрутизации

**Контекст.** Начинается офлайн-эталон (задача X-4). Первый кирпич — метрики, по которым
сравниваются планы. Их считает **один** модуль и для нашего онлайн-результата, и для
эталона: два независимых расчёта разъедутся молча, и отчёт начнёт сравнивать разное.

**Файлы.** Новый каталог `lib/offline/`, файлы `objective.rb` и `metrics.rb`.
Имя модуля — `Offline`, не `Benchmark`: `Benchmark` занят стандартной библиотекой Ruby.

**Публичный интерфейс.**

```ruby
Offline::Metrics = Data.define(:max_deviation_num, :delivered, :total, :counts)
#max_deviation_pp -> Float                 # Rational(max_deviation_num, total*100).to_f.round(1)
#key -> [Integer, Integer]                 # [-delivered, max_deviation_num] — меньше лучше
#to_block -> {'max_deviation_pp' => Float, 'delivered' => Integer}

Offline::Objective.metrics(counts:, delivered:, providers:, total:) -> Offline::Metrics
Offline::Objective.deviations_pp(counts:, providers:, total:) -> {String => Float}
Offline::Objective.from_pairs(pairs, providers:) -> Offline::Metrics
```

**Как считается — обязательно так.**

```
target_bp[p]      = provider.traffic_percentage.to_i * 100      # spacepayments: 0
deviation_num[p]  = (counts[p] * 10_000 - target_bp[p] * total).abs
max_deviation_num = максимум deviation_num по ВСЕМ провайдерам снапшота
delivered         = число операций, чей итог не :rejected       # approved и expired
```

- Отклонение меряется от **паспортной** цели `traffic_percentage`, а не от достижимой
  доли. Это осознанно отличается от `Reporting::Distributions`, который меряет от
  достижимой: `benchmark` отвечает на другой вопрос — «мог ли кто-нибудь выполнить
  паспортные цели лучше». Проверь, не соблазняйся привести к одному.
- spacepayments **входит** в максимум с целью 0: иначе сваливать заявки в fallback было бы
  бесплатно.
- Всё целочисленно. Ни `to_f`, ни `Float`, ни `round` до границы JSON. `total` одинаков
  для сравниваемых планов, поэтому делить не нужно.
- `from_pairs` принимает те же пары `[Domain::Operation, Execution::Outcome]`, что и
  `Reporting::ReportBuilder`: `counts` — по `outcome.selected.name`, `delivered` — по
  `outcome.result != :rejected`. Итерация — по массиву `providers`, не по хешу `counts`.

**Числа приёмки — публичная очередь, посчитаны при планировании.**

При распределении vipay 4 / payflow 3 / quickpay 3 / spacepayments 0 и 10 операциях:

```
vipay          |4*10000 - 4000*10| = 0
payflow        |3*10000 - 3500*10| = 5000
quickpay       |3*10000 - 2500*10| = 5000
spacepayments  |0*10000 -    0*10| = 0
max_deviation_num = 5000 -> max_deviation_pp = 5.0
delivered = 10   (8 approved + 2 expired: op_103 и op_104)
deviations_pp = {vipay 0.0, payflow -5.0, quickpay 5.0, spacepayments 0.0}
```

`deviations_pp` — знаковая величина (`counts*10_000 − target_bp*total`, делённая так же),
она нужна другому разработчику для `deviation_causes`. `max_deviation_*` — по модулю.

Если твой прогон даёт другое — остановись и скажи, не подгоняй.

**Граничные случаи.** `total == 0` → `max_deviation_num = 0`, `delivered = 0`,
`max_deviation_pp = 0.0`, без деления на ноль. Провайдер без единой операции — `counts` по
нему 0, а не отсутствие ключа. `traffic_percentage` `nil` → цель 0.

**Спеки** (`spec/offline/objective_spec.rb`):

1. Числа публичной очереди выше — все четыре строки и `max_deviation_pp == 5.0`.
2. `delivered` считает `expired` доставленной: 8 approved + 2 expired → 10.
3. `key` даёт `[-10, 5000]`; план с большим `delivered` строго лучше плана с меньшим
   отклонением (лексикографика: доставленность старше).
4. spacepayments с целью 0 и двумя операциями поднимает `max_deviation_num`.
5. `total == 0` не падает.
6. `from_pairs` на паре фикстур даёт те же числа, что прямой вызов `metrics`.
7. В модуле нет `to_f`/`Float`, кроме `max_deviation_pp` и форматирования.

**Критерий приёмки.** `bundle exec rspec spec/offline/objective_spec.rb` — 0 падений;
`make gate` зелёный. Отчёт фазой ещё не меняется: `diff` обоих выходных файлов с прогоном
до пакета пуст.

---

### БРИФ W3 — `Offline::Simulation`: пересимуляция назначения

**Контекст.** Продолжение X-4. Эталон считается постфактум и сравнивает «что было бы, если
бы заявка ушла другому провайдеру». Это вычислимо, потому что исход —
чистая функция от `(seed, operation_id, provider, attempt_no)` через SHA256
(`Execution::OutcomeSource::Deterministic`, `docs/ARCHITECTURE.md` §7).

**Здесь находится главная ловушка задачи.** `attempt_no` входит в ключ хеша. Провайдер,
который в одном плане стоит первым, а в другом вторым, обязан получить **разные** исходы.
На реальных данных: `(op_101, vipay, 1) = approved`, `(op_101, vipay, 2) = rejected`.
Поэтому кэш «исход по (operation_id, provider)» запрещён, и переносить исходы нашего
прогона в контрфактуал нельзя. Единственный разрешённый способ — **пересимулировать
очередь заново** тем же `Execution::Executor` на свежем состоянии.

**Файл.** `lib/offline/simulation.rb`.

**Публичный интерфейс.**

```ruby
Offline::Simulation.new(providers:, outcomes:, fallback_provider: 'spacepayments')
#run(operations, assignment) -> Offline::Metrics
# assignment: Array<String|nil>, длина == operations.size, индекс = позиция в очереди,
#             значение — имя провайдера, которого ставим первым в каскад (nil = не задан)
```

**Как устроен один прогон — обязательно так.**

```
state = State::Providers.new(providers)          # свежая копия исходного снапшота
executor = Execution::Executor.new(outcomes: outcomes)
для каждой операции в порядке очереди:
  live  = внешние провайдеры, допустимые по ЖИВОМУ состоянию:
          Routing::Constraints.eligible?(provider, operation, state)
  first = live.find { имя == assignment[i] }                    # может быть nil
  cascade = [first].compact + (live - [first].compact).sort_by(&:name)
  plan  = Routing::RoutePlan.new(operation:, candidates: cascade, skipped: [], trace: nil)
  out   = executor.run(plan, operation, state)
  counts[out.selected.name] += 1
  delivered += 1 unless out.result == :rejected
Offline::Objective.metrics(counts:, delivered:, providers:, total: operations.size)
```

- `Executor` сам нумерует попытки `i + 1` и сам зовёт `reserve/commit/rollback/hold`.
  Своей модели исполнения и своей нумерации попыток не пиши: вторая модель гарантированно
  разъедется с боевой.
- Пустой каскад (никто не допущен) `Executor` обрабатывает сам: fallback на spacepayments.
  Это то же правило, что в бою, — fallback по допуску, а не по исходу.
- `State::Providers.new(providers)` копирует изменяемые поля в свою таблицу и не трогает
  объекты `Domain::Provider` (они `Data`, заморожены). Поэтому каждый вызов `run` начинает
  с чистого исходного снапшота, и порядок вызовов `run` ни на что не влияет.
- Итерация по `providers` — массивом; по хешу `counts` не итерируем нигде.

**Инварианты.**

- `run` не принимает и не мутирует боевое состояние прогона. Состояние строится внутри.
- Два вызова `run` с одним `assignment` дают равные `Metrics`.
- Ни `rand`, ни `shuffle`, ни `sample`, ни `Time.now`.
- Файл не требует ничего из `lib/reporting`.

**Спеки** (`spec/offline/simulation_spec.rb`):

1. **Пересчёт `attempt_no` (главный спек пакета).** Тестовый источник исходов записывает
   все вызовы `(operation_id, provider_name, attempt_no)` и отвечает `:rejected` первому
   кандидату и `:approved` второму. Проверяется, что второй кандидат был запрошен с
   `attempt_no == 2`, а не с 1. Спек обязан падать, если реализация кэширует исход по
   `(operation_id, provider)`.
2. **Другая вселенная при перепутанном номере.** На реальном
   `OutcomeSource::Deterministic(seed: '42', conversions: калибровка из истории)`:
   `call(op_101, vipay, 1) == :approved`, `call(op_101, vipay, 2) == :rejected`. Это
   фиксирует, ради чего существует спек 1.
3. **Воспроизведение нашего прогона.** На публичной очереди `run` с назначением
   `["vipay","payflow","quickpay","quickpay","vipay","vipay","payflow","quickpay","vipay","payflow"]`
   даёт `counts` vipay 4 / payflow 3 / quickpay 3, `delivered 10`,
   `max_deviation_num 5000`. Это ровно наш фактический онлайн-результат.
4. **Идемпотентность.** Два `run` подряд с одним назначением — равные `Metrics`.
5. **Недопустимый выбор не ломает прогон.** `assignment`, назначающий payflow на op_103
   (150 000 > `limit_amount_max` 50 000), отрабатывает: payflow выпадает, операция уходит
   к quickpay.
6. **`nil` в назначении** — каскад из допустимых по возрастанию имени, без падения.
7. **Живой допуск.** Назначение, отправляющее payflow четыре заявки (op_101, op_102,
   op_107, op_110 на 103 800 ₽ при headroom 100 000 ₽), не может дать payflow четыре
   операции: дневной лимит срабатывает по живому состоянию.

**Критерий приёмки.** `bundle exec rspec spec/offline/simulation_spec.rb` — 0 падений;
`make gate` зелёный; оба выходных файла побайтово не изменились (`diff` пуст).

---

### БРИФ W4 — `Offline::Oracle`: жадный старт и локальные улучшения

**Контекст.** Завершение X-4. Есть метрики (`Offline::Objective`) и пересимуляция
(`Offline::Simulation`). Осталось искать лучшее назначение. Задача **не** разваливается на
независимые назначения: одобрение съедает `daily_amount_limit` и `in_progress`, меняя
допуск последующим заявкам. Поэтому результат — нижняя оценка, а не доказанный оптимум, и
поле в отчёте называется `offline_bound`.

**Файл.** `lib/offline/oracle.rb`.

**Публичный интерфейс.**

```ruby
Offline::Oracle.new(providers:, operations:, outcomes:, fallback_provider: 'spacepayments')
#call(online_assignment) -> Offline::Bound
Offline::Bound = Data.define(:metrics, :assignment, :passes, :simulations)

Offline::Oracle.online_assignment(pairs) -> Array<String|nil>
# имя провайдера ПЕРВОЙ попытки с decision == 'selected' в каждой паре;
# если это fallback-провайдер — nil
```

**Алгоритм — обязательно так.**

```
MAX_PASSES = 3                 # константа, не параметр конфига
LOCAL_SEARCH_MAX_OPS = 500     # свыше — только жадный старт

seed_a = online_assignment (наш фактический онлайн-план)
seed_b = жадный проход:
   состояние двигается вперёд одним прогоном Executor на операцию;
   среди допустимых по живому состоянию (отсортированных по имени) выбираем минимум
   [outcomes.call(op, p, 1) == :rejected ? 1 : 0,
    max_deviation_num на префиксе после гипотетического назначения,
    p.name]
   — исход берётся ЧИСТЫМ вызовом, состояние при переборе не мутируется
инкумбент = лучший из seed_a, seed_b по Metrics#key
локальный поиск, не более MAX_PASSES проходов:
   операции по порядку очереди;
   альтернативы = допустимые по ИСХОДНОМУ снапшоту минус текущая, по возрастанию имени;
   каждая альтернатива — полный Simulation#run;
   принимается ТОЛЬКО строгое улучшение key (first improvement);
   проход без единого улучшения завершает поиск
```

**Почему засев нашим планом обязателен.** Он гарантирует `эталон ≥ наш результат` по
построению. Без него эвристика может оказаться хуже онлайна, `competitive_ratio` станет
меньше 1.0, и отчёт начнёт врать в нашу пользу тихо и правдоподобно.

**Числа приёмки — публичная очередь, замерены прототипом при планировании.**

```
metrics.delivered          = 10
metrics.max_deviation_num  = 5000   -> 5.0 п.п.
metrics.counts             = vipay 4, payflow 3, quickpay 3, spacepayments 0
simulations                <= 20
```

Эталон совпадает с нашим онлайн-результатом: на этой очереди 5 п.п. неустранимы. quickpay
безальтернативен на op_103, op_104 и op_108, значит его доля ≥ 30 % при цели 25 %; payflow
не может взять четвёртую заявку — минимальная четвёрка 800 + 15 000 + 40 000 + 48 000 =
103 800 ₽ при свободных 100 000 ₽. Совпадение — правильный результат, а не признак того,
что поиск не работает; спек 4 ниже отличает одно от другого.

**Фикстура на 100 операций.** `spec/fixtures/queues/queue_100.json` — десять копий
`reference/data/operations_queue_10.json` с идентификаторами `op_1001…op_1100`
(порядок повторов сохраняется, `created_at` не меняется). Файл коммитится. Генератор с
`rand` в репозитории запрещён: цифры демо обязаны воспроизводиться.

**Инварианты.**

- Ни `rand`, ни `shuffle`, ни `sample`, ни `Time.now`; альтернативы и провайдеры
  перебираются по отсортированным массивам, обхода хешей нет.
- Оракул не получает и не меняет боевое состояние прогона.
- `lib/routing/**` и `lib/execution/**` не приобретают ни одной ссылки на `Offline::`.
- Поиск завершается: принимается только строгое улучшение, проходов не больше `MAX_PASSES`.

**Спеки** (`spec/offline/oracle_spec.rb`):

1. Публичная очередь: `delivered 10`, `max_deviation_num 5000`, `counts` — числа выше.
2. **Эталон не хуже нас.** Для любого переданного `online_assignment`
   `bound.metrics.key <= Simulation#run(online_assignment).key`. Проверяется в том числе
   на заведомо плохом назначении (все операции на payflow) — эталон обязан оказаться
   строго лучше.
3. `online_assignment(pairs)` берёт провайдера первой `selected`-попытки и отдаёт `nil`
   для fallback-провайдера.
4. **Поиск действительно ищет.** На заведомо плохом стартовом назначении из спека 2 число
   `simulations` больше числа стартовых точек, и `passes >= 1`.
5. Детерминизм: два вызова `call` дают равные `Bound` (включая `assignment`).
6. Пустая очередь: `delivered 0`, `max_deviation_num 0`, без падения.
7. Скорость: прогон на `spec/fixtures/queues/queue_100.json` укладывается в 5 секунд
   (замерять `Process.clock_gettime(Process::CLOCK_MONOTONIC)`; прототип дал 0.14 с).

**Критерий приёмки.** `bundle exec rspec spec/offline/oracle_spec.rb` — 0 падений;
`make gate` зелёный; оба выходных файла побайтово не изменились.

---

### БРИФ W5 — врезка в `bin/route` и заполнение блока (X-5)

**Контекст.** Эталон посчитан (`Offline::Oracle`), форма блока заморожена (W1). Осталось
соединить: посчитать блок в `bin/route` и передать в `Reporting::ReportBuilder`.

**Главный инвариант фазы:** офлайн-эталон считается **постфактум** и **никогда** не
участвует в принятии решений. Вызов стоит между `build_pairs` (все решения приняты) и
`write_outputs` (файлы ещё не записаны) — `bin/route:299–301`.

**Файлы.**

1. `lib/offline/benchmark_block.rb` — сборка блока:

```ruby
Offline::BenchmarkBlock.build(bound:, ours:, total:) -> Hash
# ключи ровно: offline_bound, our_online_result, competitive_ratio, note
```

   - `offline_bound` / `our_online_result` — `{'max_deviation_pp' => Float, 'delivered' => Integer}`;
   - `competitive_ratio = Rational(ours.max_deviation_num, bound.max_deviation_num).to_f.round(2)`;
   - `bound == 0 && ours == 0` → `1.0`;
   - `bound == 0 && ours > 0` → `nil`, и `note` дополняется абсолютным разрывом в п.п.;
   - `total.zero?` → `offline_bound` и `our_online_result` равны `nil`,
     `competitive_ratio` `nil`, `note` — «очередь пуста, эталон не считался»;
   - `bound.delivered > ours.delivered` → `note` дополняется фразой с числом
     «эталон доставил на N заявок больше»; без неё `competitive_ratio 1.0` при потерянных
     заявках выглядит как победа.

2. **Текст `note` — базовый, дословно:**

```
эталон эвристический: жадный старт и локальные улучшения с учётом порядка очереди, не доказанный оптимум; отклонение меряется от паспортных целей 40/35/25, а не от достижимых, поэтому не совпадает с distribution.deviation_pp; контрфактуалы посчитаны нашим симулятором (seed 42), а не генератором организаторов
```

   Три оговорки в нём обязательны и не сокращаются: характер эталона (оценка, не оптимум),
   база отклонения (иначе читатель увидит 0.0 в `distribution` и 5.0 в `benchmark` и решит,
   что отчёт врёт), происхождение исходов (оптимум относительно **нашего** симулятора, а
   не генератора организаторов). Seed берётся из фактически используемого значения, не
   зашивается строкой. Если поиск не запускался из-за `LOCAL_SEARCH_MAX_OPS`, `note`
   сообщает об этом с числом операций.

3. `bin/route`:
   - между `build_pairs` и `write_outputs` считается блок; источник исходов — **тот же
     объект**, что исполнял очередь (`build_outcome_source`, `bin/route:127`), а не новый;
   - блок передаётся в `write_outputs` → `Reporting::ReportBuilder.write(..., benchmark:)`;
   - `rescue` вокруг оракула не ставится: упавший эталон обязан ронять прогон, а не тихо
     класть `null` в отчёт.
   - `require_relative` новых файлов — рядом с остальными, в существующем стиле.

4. `lib/reporting/report_builder.rb` — не меняется: kwarg заведён в W1.

**Числа приёмки.** `bundle exec bin/route reference/data/operations_queue_10.json` даёт в
`routing_report_test.json`:

```json
"benchmark": {
  "offline_bound": {"max_deviation_pp": 5.0, "delivered": 10},
  "our_online_result": {"max_deviation_pp": 5.0, "delivered": 10},
  "competitive_ratio": 1.0,
  "note": "эталон эвристический: ..."
}
```

**Инварианты.**

- `routing_decisions_test.json` побайтово не меняется. Меняется только блок `benchmark`
  в отчёте; `distribution`, `projected_daily_utilization`, `fallback`, `skip_reasons`,
  `recommendations` дают прежний текст.
- Состояние боевого прогона после вызова оракула не изменилось.
- `make validate` — `❌ Ошибок: 0`.

**Спеки.**

`spec/offline/benchmark_block_spec.rb`:
1. Публичные числа: блок равен JSON выше (`note` сравнивается на вхождение подстрок
   «не доказанный оптимум», «паспортных целей», «нашим симулятором»).
2. `bound 0`, `ours 0` → `competitive_ratio == 1.0`.
3. `bound 0`, `ours > 0` → `competitive_ratio` `nil`, `note` содержит число разрыва.
4. `bound.delivered > ours.delivered` → `note` содержит число разрыва по доставленным.
5. Пустая очередь → все три значения `nil`, `note` про пустую очередь.
6. `note` всегда содержит хотя бы одну цифру (правило проекта: причина без числа не
   принимается).

`spec/bin/route_spec.rb` (дополнение, не переписывание файла):
7. Сквозной прогон на публичной очереди — блок в отчёте равен ожидаемому JSON.
8. Оракул не влияет на решения: `routing_decisions_test.json` совпадает с сохранённой
   копией прогона до пакета.

**Критерий приёмки.** `make validate` — `❌ Ошибок: 0`; `make gate` — 0 падений;
`diff` `out/routing_decisions_test.json` с прогоном до пакета пуст;
`ruby -rjson -e 'p JSON.parse(File.read("out/routing_report_test.json"))["benchmark"]'`
печатает блок с `5.0 / 10 / 5.0 / 10 / 1.0`.

---

### БРИФ W6 — гейт зоны и правка документов

**Контекст.** X-4 и X-5 закончены. Пакет закрывает то, что валидатор организаторов не
проверяет никогда.

**Что делаешь.**

1. `scripts/check_determinism.sh` — добавить `lib/offline` в массив `DIRS`. Форма проверки
   не меняется: отсутствующий каталог по-прежнему даёт exit 2, найденный источник
   случайности — exit 1. Проверить обе ветки руками.
2. Спек-греп: ни один файл в `lib/routing/**` и `lib/execution/**` не содержит `Offline`.
   Это машинная проверка инварианта «эталон не участвует в решениях»; кладётся в
   `spec/offline/isolation_spec.rb`.
3. `docs/RESEARCH.md`, идея 5 — одна фраза-пометка: результат называется `offline_bound`,
   а не `offline_optimum`, потому что задача не разваливается на независимые назначения;
   ссылка на `ARCHITECTURE.md` §12 и `TASKS.md` (оговорка 2). Сам текст идеи не
   переписывается.
4. `docs/ARCHITECTURE.md` §12 — сверить пример блока с фактическим выводом; если
   разошлись хоть одним символом, прав **вывод**, документ приводится к нему.
5. Замер времени на `spec/fixtures/queues/queue_100.json` — записать фактическую секунду
   в README-раздел или в комментарий спека, чтобы на защите цифра была замерена, а не
   названа.

**Критерий приёмки.** Зональный гейт §7 плана целиком: девять пунктов, все зелёные.

---

## 6. Что оставлено Кириллу как контракт (A-7, X-6)

Спеки Кирилл пишет сам, кодер Вовы их не трогает. От нас — форма блока, числа и одна
публичная функция.

**Замораживается после PASS по W1 (форма) и W5 (числа):**

1. **Форма блока `benchmark`** — §3.1, четыре ключа, вложенность, типы. После W1 не
   меняется. A-7 может начинаться сразу после W1, не дожидаясь W4/W5.
2. **База отклонения для `deviation_causes` — паспортная цель `traffic_percentage`,** та
   же, что в `benchmark`. Это согласуется с фикстурой `spec/fixtures/contracts/report.json`
   («quickpay +5 п.п. **к цели**»). Числа публичной очереди, от которых A-7 обязан
   отталкиваться: vipay 0.0, payflow **−5.0**, quickpay **+5.0**, spacepayments 0.0.
   Внимание на шов: `distribution.*.deviation_pp` в том же файле меряет от **достижимой**
   доли и равен 0.0 у всех. Это два разных числа с похожими именами; A-7 обязан явно
   сказать, от чего меряет.
3. **Готовая функция вместо повторного счёта:**
   `Offline::Objective.deviations_pp(counts:, providers:, total:) -> {имя => Float}`,
   знаковая величина. Пересчитывать отклонения своим кодом не нужно и вредно: два расчёта
   разъедутся.
4. **Аргумент для текста причины.** Отклонения 5 п.п. на публичной очереди неустранимы, и
   у нас есть этому два доказательства: quickpay безальтернативен на op_103, op_104,
   op_108 (доля ≥ 30 % при цели 25 %), а payflow не может взять четвёртую заявку —
   минимальная четвёрка 800 + 15 000 + 40 000 + 48 000 = 103 800 ₽ при свободных
   100 000 ₽. Эталон это подтверждает числом: `offline_bound.max_deviation_pp == 5.0`.
   Формулировка «наш промах» в `deviation_causes` была бы неправдой.
5. **Для X-6 (обратная задача) ничего нового не требуется:** ближайшие достижимые доли уже
   считает `Routing::Achievable.for_queue` (R-12) — 40 / 30 / 30 на публичной очереди.
   Эталон эту машинерию не заменяет и не дублирует.

Чего у нас **нет** и чего не будет: оракул не отдаёт пооперационных объяснений («почему
эталон отправил op_105 туда»). Если A-7 такое понадобится — это отдельная задача, не
входящая в Ф5.

---

## 7. Гейт зоны Вовы в Ф5

Зона закрыта, когда одновременно:

1. `make gate` — rspec 0 падений (было 478 примеров, стало больше), rubocop 0 замечаний,
   `make no-random` чист, включая новый каталог `lib/offline`.
2. `make validate` — `✅ Пройдено: 29`, `❌ Ошибок: 0`, `⚠️ Предупр.: 0`.
3. `make determinism` — `детерминизм: OK`.
4. `routing_decisions_test.json` побайтово совпадает с прогоном до фазы. Фаза не имеет
   права двигать ни одно решение — это и есть проверка инварианта «эталон постфактум».
5. В `routing_report_test.json` изменился **только** блок `benchmark`:
   `diff` остальных секций с прогоном до фазы пуст.
6. Блок равен эталону дословно:
   `offline_bound {5.0, 10}`, `our_online_result {5.0, 10}`, `competitive_ratio 1.0`,
   `note` непустая и содержит цифры.
7. Время: прогон оракула на `spec/fixtures/queues/queue_100.json` — меньше 5 секунд
   (прототип при планировании дал 0.14 с на 100 операциях, 71 симуляцию).
8. Изоляция: `grep -rn 'Offline' lib/routing lib/execution` — пусто.
9. Чужие спеки не тронуты: `git diff --name-only` не содержит `spec/config/*`,
   `spec/state/*`, `spec/execution/*`, `spec/io/*`, `lib/state/*`, `lib/execution/*`,
   `lib/io/*`, `lib/config/*`, `lib/routing/*`. Из `lib/reporting/` изменён только
   `report_builder.rb`, и в нём — только метод `benchmark` и сигнатуры `build`/`write`.

Пункты 4–9 валидатор организаторов не проверяет вообще: он остаётся зелёным и при
полностью выдуманном блоке `benchmark`. Гейт зоны шире гейта организаторов именно поэтому.

---

## 8. Что может сломаться молча

| Что | Почему тихо | Чем ловится |
|---|---|---|
| Оракул кэширует исход по `(operation_id, provider)` без `attempt_no` | Числа остаются правдоподобными, но эталон живёт в другой вселенной; ни гейт, ни валидатор не заметят | W3 спек 1 (двойник источника фиксирует запрошенный `attempt_no == 2`) и спек 2 (`op_101/vipay`: 1 → approved, 2 → rejected) |
| Оракулу подсунут другой источник исходов: паспортные конверсии вместо калиброванных или другой seed | `competitive_ratio` посчитается и будет выглядеть осмысленно; сравниваются два разных мира | W5: источник берётся из единственной точки построения `bin/route:127`; гейт п. 6 — блок обязан дать ровно 5.0/10/5.0/10/1.0 |
| Эталон не засеян нашим планом и оказался хуже онлайна | `competitive_ratio < 1.0` читается как «мы лучше идеала» и звучит на защите как победа | Инвариант §3.3 п. 5 + W4 спек 2 (`bound.key <= ours.key` для любого назначения) |
| Отклонение в `benchmark` посчитано от достижимой доли вместо паспортной цели | Даёт 0.0 против 0.0, конвенция 0/0 отдаёт `competitive_ratio 1.0`, блок зелёный и пустой | Гейт п. 6: `our_online_result.max_deviation_pp` обязан быть 5.0, а не 0.0; W2 спек 1 |
| `delivered` считает только `approved` | 8 против 8, отношение 1.0, всё сходится — но противоречит Q&A про `expired` и примеру §12 | W2 спек 2: 8 approved + 2 expired → `delivered == 10` |
| Оракул мутировал боевое состояние прогона | Решения уже приняты и не изменятся, а `projected_daily_utilization` и `recommendations` поедут | W3 инвариант «состояние строится внутри» + гейт п. 5 (все секции отчёта, кроме `benchmark`, побайтово прежние) |
| Оракул вызван до цикла очереди или его результат просочился в планирование | Онлайн-инвариант нарушен, дисквалифицирующий довод на защите; тесты при этом зелёные | Гейт п. 4 (decisions побайтово) + п. 8 (`grep Offline` по `lib/routing`, `lib/execution`) + W6 спек изоляции |
| Падение оракула обёрнуто в `rescue` и блок молча уехал в `null` | Валидатор зелёный, отчёт валидный, эталона нет — узнаём на защите | W5: `rescue` запрещён; гейт п. 6 требует конкретных чисел, а не «поле присутствует» |
| `competitive_ratio 1.0` при том, что эталон доставил больше заявок | Отношение считается по отклонению и молчит о потерянных деньгах | W5 спек 4: разрыв по `delivered` обязан попасть в `note` числом |
| Подсчёт распределения идёт обходом хеша `counts` | Порядок вставки зависит от того, кто первым получил заявку; tie-break поедет на другой очереди | §3.5: итерация только по массиву `providers`; W2 спек 4 (провайдер с нулём операций присутствует в расчёте) |
| Локальный поиск принимает нестрогие улучшения | Зацикливание либо зависимость результата от порядка обхода; на 10 заявках незаметно, на 100 — таймаут демо | W4: только строгое улучшение, `MAX_PASSES` константой; W4 спек 5 (детерминизм) и спек 7 (время) |
| Фикстура на 100 операций сгенерирована с `rand` | Перегенерация меняет числа скорости и результата; на защите цифра не воспроизводится | W4: файл коммитится, генератор без случайности; `check_determinism.sh` расширен на `lib/offline` (W6) |
| Форма блока правится позже A-7 | Кирилл строит `deviation_causes` на одной форме, отчёт отдаёт другую; ломается за сутки до защиты | W1 идёт первым пакетом фазы и до начала A-7; §6 — контракт с датой заморозки |
| Две разные «deviation_pp» в одном файле (0.0 в `distribution`, 5.0 в `benchmark`) | Жюри читает отчёт как противоречивый и снимает баллы за аналитику | `note` обязана назвать базу каждого числа; W5 спек 1 проверяет вхождение фразы про паспортные цели |

---

## 9. Порядок исполнения и риски

1. **W1** — первым и отдельным коммитом, с уведомлением Кириллу. Он разблокирует A-7 и не
   зависит ни от чего. Пока форма не заморожена, любая работа Кирилла над
   `deviation_causes` — работа в долг.
2. **W2** — метрики. Отдельный пакет намеренно: пока база отклонения не зафиксирована
   числом 5000, спорить об эталоне бессмысленно.
3. **W3** — пересимуляция. Здесь единственный по-настоящему тихий баг фазы (`attempt_no`),
   поэтому пакет отделён от поиска: спек 1 обязан быть красным на неправильной реализации.
4. **W4** — поиск. Делать только после зелёного W3.
5. **W5** — врезка и X-5. Только после W4.
6. **W6** — после PASS по W5.

**Риски.**

- *Совпадение эталона с нашим результатом (5.0 / 5.0, ratio 1.0).* Выглядит как «оракул
  ничего не делает». На публичной очереди это правильный ответ — 5 п.п. арифметически
  неустранимы (§3.4). Митигируется W4 спеком 2 и 4: на заведомо плохом старте эталон
  обязан строго улучшаться. На защите про это говорится сразу, до вопроса жюри.
- *Соблазн переносить исходы вместо пересимуляции ради скорости.* Скорость не нужна:
  0.14 с на 100 операциях. Любая оптимизация, кеширующая исход без `attempt_no`, ломает
  корректность и запрещена планом.
- *Соблазн назвать результат оптимумом.* `RESEARCH.md` так и называет. Задача не
  разваливается на независимые назначения, гарантий оптимальности у жадного поиска с
  локальными улучшениями нет. Имя `offline_bound` и `note` — часть контракта, а не стиль.
- *Правка `lib/reporting/report_builder.rb` в зоне Кирилла.* Единственная разрешённая, по
  именному исключению `OWNERSHIP.md`. Митигируется минимальностью (метод + kwarg) и
  уведомлением до мержа.
- *Числа плана привязаны к `seed: 42`, `calibrate_from_history: true` и
  `reference/data/*`.* Любая правка seed, конверсий или данных сдвигает всю таблицу §0.
  Если это произошло — таблица **перемеряется**, а не подгоняется под спек.
- *Блок `benchmark` — единственное место фазы, видимое жюри.* Если фаза режется
  (`TASKS.md`, очередь реза, пункт 4), режется целиком; полуготовый блок с `null` хуже
  честной заглушки с `note`.

---

## 10. Список пакетов (сводка)

| ID | Пакет | Одна команда приёмки |
|---|---|---|
| W1 | Форма блока `benchmark` заморожена: вложенный контракт, фикстура, два спека | `make gate` + `make validate` + пустой `diff` decisions |
| W2 | `Offline::Objective` / `Offline::Metrics`: отклонение от паспортной цели, `delivered`, кортеж | `bundle exec rspec spec/offline/objective_spec.rb` |
| W3 | `Offline::Simulation`: пересимуляция назначения через `Executor` с пересчётом `attempt_no` | `bundle exec rspec spec/offline/simulation_spec.rb` |
| W4 | `Offline::Oracle`: жадный старт, локальные улучшения, засев нашим планом, фикстура 100 операций | `bundle exec rspec spec/offline/oracle_spec.rb` |
| W5 | Врезка в `bin/route`, реальные числа и `note` в блоке (X-5) | `make validate` + сверка блока с эталонным JSON |
| W6 | Гейт зоны, `check_determinism.sh` на `lib/offline`, пометка в `RESEARCH.md` | §7 целиком |
