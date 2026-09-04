# Ф3 — Конфигурация и расширяемость. План работ Вовы (CFG-2, CFG-3)

Источники: `docs/SCOPE.md` (§4.3, §4.4) → `docs/ARCHITECTURE.md` (§14) → `docs/TASKS.md`
(раздел «Ф3 — Семь стратегий и конфигурация») → `docs/OWNERSHIP.md` → `AGENTS.md` →
`docs/plans/PHASE_2_VOVA.md` → `reference/scripts/validate_10.rb`. Числа в плане получены
прогонами на `reference/data/operations_queue_10.json`, а не оценены.

**Зона плана.** Только CFG-2 («подмена активной стратегии и набора слоёв из конфига»,
1.0 ч) и CFG-3 («новая стратегия = файл + строка в конфиге», 0.5 ч). S-3…S-7, CFG-1 и T-3
закрыты Кириллом и в план не входят; границы с ними — в §2.

**Гейт фазы (из TASKS.md):** семь стратегий переключаются конфигом, каждая даёт свой
порядок на op_101. Часть гейта, за которую отвечает Вова: переключение происходит **строкой
YAML**, а не флагом CLI, и при любой из семи стратегий `make validate` остаётся зелёным.

---

## 0. Фактическое состояние репозитория (проверено запуском, не по памяти)

`make gate` — 393 примера, 0 падений, rubocop 103 файла без замечаний. `make validate` —
`✅ 29 / ❌ 0`. Это подтверждено, дальше только то, что план меняет.

**Что уже есть и работает.**

- `lib/config/` (CFG-1, Кирилл): `Loader.load(path) -> Config::RoutingConfig`,
  `SchemaValidator`, `SchemaRules`, `SchemaError < RuntimeError`. Все восемь ключей §14
  валидируются по форме. `spec/config/loader_spec.rb` — 12+ примеров, включая фикстуры
  битых конфигов.
- Семь стратегий зарегистрированы: `Routing::Strategies.known` →
  `["amount_range", "conversion", "count_share", "load", "obligations", "priority",
  "volume_share"]`.
- `Routing::Strategies.build(name)` — `registry.fetch(name.to_s).new`, аргументов не
  принимает. `spec/support/shared/strategy_contract.rb:45` вызывает
  `Routing::Strategies.build(subject.name)` **без конфига** для каждой из семи стратегий —
  это ограничение на любую правку `build`.
- `Routing::Planner#initialize(providers:, fallback_provider: 'spacepayments', strategy:)`
  — точка врезки уже есть, стратегия инжектится снаружи.

**Что мёртво.**

- `config/routing.yml` в шапке файла сам про себя пишет: «этот файл сейчас ни на что не
  влияет». Единственный код, который его открывает, —
  `lib/routing/strategies/amount_range.rb:24`:
  `@default_ranges ||= Config::Loader.load(CONFIG_PATH).amount_ranges`. Класс стратегии
  сам лезет в файловую систему в обход пайплайна.
- `bin/route`, `default_options`: `strategy: 'count_share'` — хардкод. Конфига `bin/route`
  не читает вообще, `--config` нет.
- `bin/route` требует шесть файлов стратегий поимённо (`require_relative
  '../lib/routing/strategies/volume_share'` … `/obligations'`). Новая стратегия сегодня
  **требует правки `bin/route`** — прямое противоречие критерию CFG-3.
- `lib/routing/layers/` содержит только `base.rb` с `NotImplementedError`. Реестра слоёв
  нет. `layers: []` в конфиге валидируется как «список строк» и никуда не едет.
- `README.md` в репозитории отсутствует.

**Измеренные распределения по `selected_provider` на публичной очереди** (10 операций,
`--outcomes deterministic --seed 42`, то есть дефолты `bin/route`). Валидатор на каждой из
семи — `✅ Пройдено: 29 / ❌ Ошибок: 0`:

| `--strategy` | vipay | payflow | quickpay | approved |
|---|---|---|---|---|
| `count_share` | 3 | 3 | 4 | 8 |
| `volume_share` | 4 | 3 | 3 | 8 |
| `priority` | 4 | 3 | 3 | 8 |
| `amount_range` | 3 | 4 | 3 | 8 |
| `conversion` | 4 | 2 | 4 | 7 |
| `load` | **0** | 2 | **8** | 7 |
| `obligations` | **0** | 4 | 6 | 8 |

Это опорная таблица фазы: все числа ниже сверяются с ней.

---

## 1. Противоречия в постановке (называю, не решаю молча)

### C-1. `layers` в §14 архитектуры есть, слоёв в коде нет и в Ф3 не будет

`ARCHITECTURE.md` §14 показывает `layers: [conversion, load, obligations]` как рабочий
пример. `TASKS.md` относит слои к Ф4 (X-1 лексикографическое ЦП, X-2 ψ-слой, X-3
`Selector`). `SCOPE.md` §4.3 описывает слои как отдельный уровень поверх базовой стратегии.
Приоритет SCOPE → ARCHITECTURE → TASKS противоречия не снимает: SCOPE говорит «слои есть»,
TASKS говорит «в Ф4». Это расхождение по срокам, не по смыслу.

**Прямой ответ на вопрос «что делать со `layers: []` в CFG-2»:** в Ф3 делается
**валидируемый пустой список с явным поведением**, реальной подстановки слоёв нет.
Конкретно:

- появляется `Routing::Layers` — реестр-близнец `Routing::Strategies`, с пустым `REGISTRY`;
- `layers: []` → пайплайн работает как сейчас, ноль изменений в выводе;
- `layers: [что_угодно]` → `bin/route` падает с кодом 1 и сообщением
  «неизвестный слой "conversion"; известные слои: (реестра слоёв пока нет, слои приезжают
  в Ф4)».

Почему именно так, а не «молча игнорировать непустой список»: молчаливое игнорирование —
это ровно тот тихий отказ, который на защите выглядит как работающая фича. Человек пишет
`layers: [conversion]`, распределение не меняется, и никто не замечает. Ф4 (X-1…X-3)
получает готовую точку врезки: зарегистрировать класс в `Layers` и применить список в
`Planner` после `strategy.rank`. Применение слоёв в `Planner` **в Ф3 не делается** — это
работа X-1/X-2, и в чужую фазу план не лезет.

### C-2. `conversion`, `load`, `obligations` — это одновременно стратегии и слои

`SCOPE.md` §4.3 перечисляет модификаторы `[conversion] → [load] → [obligations] →
[amount_range]`. `TASKS.md` S-5, S-6, S-7 делает ровно эти же имена **стратегиями**, и
Кирилл их уже написал. Одно имя — две разные сущности с разными контрактами (`rank` против
`adjust`).

Решение: реестры **раздельные**. `Routing::Layers` не смотрит в `Routing::Strategies`
никогда. Если бы `layers: [conversion]` подхватывал `Strategies::Conversion`, оно бы
формально «заработало» — вернуло бы перестановку — и выглядело бы как реализованный слой,
которого нет. В Ф4 слой называется `Layers::Conversion` и живёт в `lib/routing/layers/`.

### C-3. Конфиг обещает больше, чем влияет: `obligations` и `rate_limits` декоративны

Проверено: `reference/data/providers.json` не содержит полей `daily_turnover_min`,
`daily_turnover_max`, `requests_per_minute_limit`, `volume_share_pct` —
`lib/io/providers_loader.rb:25-26` честно превращает их в `nil`. Следствия:

- `Strategies::Obligations` на реальном снапшоте вырождается: у всех `min`/`max` = `nil`,
  `tier` всегда 1, `secondary` всегда 0, сортировка идёт по `provider.name`. Измеренное
  распределение `payflow 4 / quickpay 6 / vipay 0` — это алфавит, а не финансовые
  обязательства.
- `Constraints::RateLimit` — no-op: лимит `nil`.
- Секции `obligations:` и `rate_limits:` в `config/routing.yml` не читает никто.

Два варианта, последствия:

**A (рекомендую для Ф3).** Не трогаем поведение. В README появляется честная таблица «ключ
конфига → на что влияет сегодня», где `obligations`, `rate_limits`,
`outcomes.calibrate_from_history` помечены «схема валидируется, поведение не подключено».
Цена: на защите вопрос «а покажите, как `daily_turnover_min` поднимает провайдера» имеет
ответ только на синтетических провайдерах из спека. Риск для гейта — ноль.

**B.** Оверлей конфига на снапшот провайдеров: `obligations`/`rate_limits` из YAML
дописывают отсутствующие поля `Domain::Provider`. Цена: `rate_limits: {vipay: 7}` включает
живой hard-constraint `rate_limit_exceeded`, а это правка семантики допуска — зона Вовы, но
не задача CFG-2, и она может увести выбор в `spacepayments` на эталонном кейсе. Требует
полного перепрогона валидатора и, по-хорошему, отдельной задачи в Ф5.

Вариант B в этой фазе не делаем. Если человек выберет B — это отдельный пакет после гейта
Ф3, не внутри него.

### C-4. CFG-3 «без правок ядра» неверно уже сегодня

Критерий CFG-3 — «новая стратегия = файл + строка в конфиге, без правок ядра». Фактически
нужна ещё третья правка: `require_relative` в `bin/route`. Пока это так, README будет
описывать не то, что происходит. Поэтому автозагрузка каталога стратегий — не украшение, а
обязательная часть CFG-3 (пакет W5).

### C-5. Приоритет `--strategy` над YAML в постановке не определён

`TASKS.md` про CLI молчит. Решение (замораживается, см. §3): **CLI перекрывает YAML**,
YAML перекрывает отсутствие значения, кода-дефолта `'count_share'` больше нет вообще.
Обоснование: конфиг — источник истины для боевого прогона (`make validate`, `make
deliver`), а `--strategy` остаётся инструментом сравнения стратегий на одной очереди, без
которого нельзя за минуту показать таблицу из §0. Убрать флаг — потерять демо; сделать флаг
главнее конфига нельзя иначе — тогда конфиг снова мёртв в любом прогоне с флагом.

### C-6. Бюджет 1.5 ч против объёма

`TASKS.md` даёт CFG-2 + CFG-3 = 1.5 ч. План весит 4.25 ч (§4). Разница — это не раздувание
скоупа, а три вещи, которых в бюджете нет: отсутствующий `README.md` целиком, автозагрузка
стратегий (C-4) и реестр слоёв (C-1). Что снимается при нехватке времени — в §4.

---

## 2. Точки стыка с чужими зонами

| Файл | Владелец | Что делаем | Как согласовано |
|---|---|---|---|
| `lib/routing/strategies/amount_range.rb` | Кирилл (S-4) | убираем `CONFIG_PATH` и `self.default_ranges`, добавляем `self.from_config` | правка на 8 строк, публичный контракт `new(ranges:)` не меняется, `spec/routing/strategies/amount_range_spec.rb` не трогаем — он уже инжектит полосы |
| `lib/config/*` | Кирилл (CFG-1) | **не трогаем ни строки** | `RoutingConfig` потребляется как есть; новых ключей схемы не вводим |
| `config/routing.yml` | Кирилл | правим только комментарий-шапку («файл ни на что не влияет» становится неправдой) | значения ключей не меняем: любое изменение сдвинет числа §0 |
| `bin/route` | общий композиционный корень | добавляем `--config`, читаем конфиг, снимаем хардкод стратегии и шесть `require` | Кириллу и Максиму уходит уведомление: CLI-флаги стали шире, дефолт стратегии теперь берётся из YAML |
| `lib/execution/*`, `lib/state/*` | Максим | не трогаем | конфиг до них не доезжает даже в W3b |
| `spec/support/shared/strategy_contract.rb` | Кирилл | **не трогаем** | поэтому `Strategies.build(name)` обязан продолжать работать без конфига |

---

## 3. Что заморожено в этой фазе

### 3.1 Кто читает конфиг и как он доезжает до стратегии

Ответ: **`bin/route` на старте, ровно один раз, до сборки пайплайна.** Ни `Planner`, ни
стратегия, ни `Executor` файловой системы не касаются.

```
bin/route                                   ← единственный, кто знает путь к YAML
  Config::Loader.load(options[:config_path]) -> Config::RoutingConfig
  Routing::Assembly.strategy(config:, override: options[:strategy]) -> Strategies::Base
  Routing::Assembly.layers(config:)                                 -> []
  Routing::Planner.new(providers:, strategy:, fallback_provider: config.fallback_provider)
```

Новый файл `lib/routing/assembly.rb` (зона Вовы) — вся логика «конфиг + CLI → объекты».
Она в `lib/`, а не в `bin/route`, чтобы проверяться быстрым юнит-спеком, а не запуском
процесса.

Публичные сигнатуры, замораживаются:

```ruby
module Routing
  module Assembly
    # override: значение --strategy или nil, если флаг не передавали.
    # KeyError с сообщением, называющим источник имени (CLI или config).
    def self.strategy(config:, override: nil) # -> Routing::Strategies::Base

    # Пока всегда []. Непустой config.layers -> KeyError.
    def self.layers(config:) # -> [Routing::Layers::Base]
  end
end

module Routing
  module Strategies
    # config: nil сохраняет текущее поведение (klass.new) — от этого зависит
    # spec/support/shared/strategy_contract.rb, его править нельзя.
    def self.build(name, config: nil) # -> Strategies::Base
  end
end
```

**Протокол доставки конфига в стратегию.** Класс стратегии, которому нужны данные из
конфига, объявляет фабрику:

```ruby
def self.from_config(config) = new(ranges: config.amount_ranges)
```

`Strategies.build` вызывает `klass.from_config(config)`, если `config` передан **и** класс
отвечает на `from_config`; иначе `klass.new`. Одна необязательная точка расширения, ноль
знаний реестра о конкретных классах, `AmountRange` перестаёт открывать файлы.

### 3.2 Дефолт `AmountRange` без конфига — пустые полосы, а не копия YAML

`AmountRange.new` без аргументов обязан работать (shared-контракт стратегий). Дефолт —
**`[]`**, то есть «ни одна полоса не совпала», и стратегия честно вырождается в порядок по
`priority` (это поведение уже зафиксировано спеком «без совпавшей полосы падает обратно на
priority»). Константа с копией полос из YAML запрещена: две копии одних и тех же чисел
разъедутся молча, и никакой спек этого не поймает без сверки с боевым конфигом, которую
сам же демо-сценарий CFG-2 и ломает (он меняет полосу в YAML).

Обратная сторона решения — тихий отказ «конфиг не доехал, стратегия молча стала priority».
Ловится сквозным спеком из W4 (см. §7).

### 3.3 Приоритет источников

```
--strategy NAME  (CLI)        сильнее
config.strategy  (YAML)
—                             кода-дефолта нет: default_options теряет strategy: 'count_share'
```

Отсутствие ключа `strategy` в YAML уже невозможно: `SchemaValidator.validate_required!`
требует непустую строку. Значит после снятия хардкода стратегия всегда имеет источник, и
источник всегда называется в сообщении об ошибке.

### 3.4 Правило имени: файл = имя стратегии

`lib/routing/strategies/<name>.rb` регистрирует стратегию с `name == '<name>'`. Все семь
существующих файлов уже подчиняются правилу. Правило проверяется спеком (W5) и является
основанием для автозагрузки каталога.

### 3.5 Детерминизм

Автозагрузка — `Dir[...].sort.each { require }`, **обязательно `sort`**: порядок `Dir.glob`
зависит от файловой системы, а порядок регистрации влияет на порядок `REGISTRY` и на текст
сообщений об ошибках (`known.join(', ')` спасает сортировкой, но полагаться на это нельзя).
Никакого `rand`, `Time.now`, никаких хешей с порядком вставки в решающем пути. `make
no-random` и `make determinism` остаются частью гейта зоны.

---

## 4. Пакеты работ

| ID | Пакет | TASKS | Зависит | Проверяется одной командой |
|---|---|---|---|---|
| W1 | `Strategies.build(name, config:)` + протокол `from_config`; `AmountRange` перестаёт читать файл | CFG-2 | — | `make gate` |
| W2 | `Routing::Layers` (пустой реестр) + `Routing::Assembly` (стратегия, слои, приоритет CLI над YAML) | CFG-2 | W1 | `make gate` |
| W3 | Врезка в `bin/route`: `--config`, чтение конфига на старте, снятие хардкода `count_share`, `fallback_provider` из конфига | CFG-2 | W2 | `make validate` → `❌ Ошибок: 0` |
| W4 | Сквозной спек «одна строка YAML меняет распределение» + проверка боевого конфига | CFG-2 | W3 | `bundle exec rspec spec/bin/config_switch_spec.rb` |
| W5 | Автозагрузка `lib/routing/strategies/*.rb`, `bin/route` теряет шесть `require`, спек «реестр = каталог» | CFG-3 | W1 | `make gate` |
| W6 | `README.md` + одноминутное демо расширяемости (`scripts/demo_new_strategy.sh` + `docs/examples/reverse_priority.rb`) | CFG-3 | W4, W5 | `bash scripts/demo_new_strategy.sh` |
| W3b | *(опционально)* `outcomes.source` и `outcomes.seed` из конфига | сверх CFG-2 | W3 | `make validate` + побайтовое совпадение с прогоном до правки |
| W7 | Гейт зоны: регрессия, детерминизм, семь стратегий через валидатор | — | W4, W6 | `make gate`, `make validate`, `make determinism`, цикл из §6 |

Граф:

```
W1 ──┬── W2 ── W3 ── W4 ──┬── W6 ── W7
     └── W5 ──────────────┘
                W3 ── W3b (опц.)
```

Часы: W1 0.5, W2 0.5, W3 0.75, W4 0.75, W5 0.5, W6 0.75, W3b 0.25, W7 0.25 — **4.25 ч**
против 1.5 ч в `TASKS.md`.

**Что снимается при нехватке времени, в этом порядке:** W3b (ничего не разблокирует),
затем демо-скрипт из W6 (README остаётся, живое демо заменяется словами). W1–W5 не
снимаются: без них критерий CFG-2 не выполнен буквально — «смена одной строки», а не
«смена флага».

---

## 5. Брифы кодеру

Каждый бриф самодостаточен: кодер плана не видел. Один бриф — один заход.

---

### БРИФ W1 — конфиг доезжает до стратегии, стратегия не читает файлы

**Контекст.** `lib/routing/strategies/amount_range.rb` сегодня сам открывает
`config/routing.yml` (`CONFIG_PATH`, `self.default_ranges`, `Config::Loader.load`). Это
единственное место в проекте, где класс из решающего пути лезет в файловую систему в обход
пайплайна. Конфиг должен приходить сверху.

**Файлы.**

1. `lib/routing/strategies.rb` — расширить фабрику:

```ruby
def build(name, config: nil)
  klass = registry.fetch(name.to_s)
  return klass.from_config(config) if config && klass.respond_to?(:from_config)

  klass.new
rescue KeyError
  raise KeyError, "unknown strategy #{name.inspect}; known: #{known.join(', ')}"
end
```

`config` — объект `Config::RoutingConfig` (см. `lib/config/routing_config.rb`), реестр про
его внутренности ничего не знает и знать не должен. `rescue KeyError` обязан продолжать
ловить именно промах `registry.fetch`, не ошибки внутри `from_config`.

2. `lib/routing/strategies/amount_range.rb` — минимальная правка:

- удалить `require_relative '../../config/loader'`, константу `CONFIG_PATH`, метод
  `self.default_ranges` и мемоизацию;
- `def initialize(ranges: [])` — дефолт **пустой список**, не копия полос из YAML;
- добавить `def self.from_config(config) = new(ranges: config.amount_ranges)`;
- поправить комментарий класса: полосы приходят из конфига через `Strategies.build(name,
  config:)`, файл класс не открывает.

Публичный контракт `new(ranges:)` не меняется — `spec/routing/strategies/amount_range_spec.rb`
трогать нельзя, он должен проходить как есть.

**Инварианты.**

- `Strategies.build(name)` **без** `config` обязан работать для всех семи имён и возвращать
  объект соответствующего класса: от этого зависит
  `spec/support/shared/strategy_contract.rb:45`, который править запрещено.
- Пустые полосы — легальное состояние: ни одна полоса не совпадает, `AmountRange` даёт
  порядок по `priority`, исключений не бросает (спек на это уже есть).
- Никаких констант с продублированными числами полос. Полосы живут только в
  `config/routing.yml`.
- В `lib/routing/` не появляется ни одного нового обращения к файловой системе.

**Спеки, которые должны появиться** (`spec/routing/strategies_config_spec.rb`):

1. `Strategies.build('amount_range')` без конфига → объект, `rank` на операции 15 000 даёт
   порядок по `priority` (полос нет).
2. `Strategies.build('amount_range', config: cfg)`, где `cfg` — `Config::RoutingConfig` с
   полосами `500..50000 → payflow`, → на операции 15 000 первый `payflow`.
3. `Strategies.build('priority', config: cfg)` → объект `Strategies::Priority`; конфиг
   классу без `from_config` не мешает.
4. `Strategies.build('нет_такой', config: cfg)` → `KeyError`, сообщение содержит перечень
   известных имён.
5. Грep-спек или явная проверка: `Routing::Strategies::AmountRange` не определяет
   `CONFIG_PATH` (`expect(described_class.const_defined?(:CONFIG_PATH)).to be(false)`) —
   ловит откат к самозагрузке файла.

**Граничные случаи.** `config.amount_ranges` может быть `[]` (ключ отсутствует в YAML —
`Loader.build_config` подставляет пустой массив). Ключи полос — **строки**
(`'from'`, `'to'`, `'prefer'`), потому что приходят из сырого YAML; символы не поддерживаем.

**Критерий приёмки.** `make gate` — 0 падений, rubocop 0 замечаний.

---

### БРИФ W2 — реестр слоёв и сборка пайплайна из конфига

**Контекст.** Конфиг содержит ключи `strategy` и `layers`. Слоёв в проекте нет:
`lib/routing/layers/` содержит только `base.rb` с абстрактным `adjust`. Нужен объект,
который превращает конфиг плюс CLI-переопределение в готовые объекты, и который проверяется
юнит-спеком без запуска процесса.

**Файлы.**

1. `lib/routing/layers.rb` — реестр-близнец `lib/routing/strategies.rb`. Скопировать его
   структуру (`REGISTRY`, `register`, `build`, `known`), но:
   - `REGISTRY` пустой, ни одного `register`;
   - `build(name)` бросает `KeyError` с сообщением
     `"unknown layer \"conversion\"; слоёв пока нет: они приезжают в Ф4 (X-1, X-2)"`;
   - `known` возвращает `[]`.
   - `Layers` **не смотрит** в `Strategies`: `layers: [conversion]` не должен подхватывать
     `Strategies::Conversion`, это разные контракты (`adjust` против `rank`).

2. `lib/routing/assembly.rb` — новый модуль:

```ruby
module Routing
  module Assembly
    def self.strategy(config:, override: nil)  # -> Strategies::Base
    def self.layers(config:)                   # -> Array (сейчас всегда пустой)
  end
end
```

- `strategy`: имя = `override`, если оно не `nil` и не пустое, иначе `config.strategy`.
  Источник запоминается ради сообщения об ошибке. Возврат — `Strategies.build(name,
  config: config)`. Неизвестное имя → `KeyError`, текст обязан называть источник:
  `Неизвестная стратегия "conv" (источник: --strategy); допустимы: amount_range, ...`
  либо `... (источник: config/routing.yml, ключ strategy); ...`.
- `layers`: `config.layers` пуст → `[]`; иначе `Layers.build(name)` по каждому имени, то
  есть `KeyError` на первом же. Ленивого игнорирования нет.

**Инварианты.**

- CLI сильнее YAML, кода-дефолта стратегии не существует.
- `Assembly` ничего не читает с диска: конфиг приходит объектом.
- Никакой мутации `config`.

**Спеки** (`spec/routing/assembly_spec.rb`), конфиг собирается вручную
`Config::RoutingConfig.new(...)`, файлы не читаются:

1. `strategy(config: cfg(strategy: 'load'))` → `Strategies::Load`.
2. `strategy(config: cfg(strategy: 'load'), override: 'priority')` → `Strategies::Priority`
   — CLI перекрывает YAML.
3. `strategy(config: cfg(strategy: 'load'), override: nil)` → `Strategies::Load` — nil не
   считается переопределением.
4. `strategy(config: cfg(strategy: 'amount_range', amount_ranges: [...]))` → полосы доехали:
   `rank` на 15 000 ставит `payflow` первым.
5. `strategy(config: cfg(strategy: 'нет_такой'))` → `KeyError`, сообщение содержит
   `config/routing.yml`.
6. `strategy(config: cfg(strategy: 'load'), override: 'нет_такой')` → `KeyError`, сообщение
   содержит `--strategy`.
7. `layers(config: cfg(layers: []))` → `[]`.
8. `layers(config: cfg(layers: ['conversion']))` → `KeyError`; сообщение упоминает Ф4.
9. `Routing::Layers.known` → `[]`, и `Layers.build('conversion')` не возвращает
   `Strategies::Conversion` (реестры раздельные).

**Критерий приёмки.** `make gate` — 0 падений, rubocop 0 замечаний.

---

### БРИФ W3 — `bin/route` читает конфиг

**Контекст.** `bin/route` — единственная точка входа и композиционный корень. Сейчас он
хардкодит `strategy: 'count_share'` в `default_options` и конфиг не открывает. После этого
пакета боевой прогон (`make validate`, `make deliver`) управляется файлом
`config/routing.yml`.

**Файл.** Только `bin/route` (и одна строка комментария в `config/routing.yml`, см. ниже).

**Что сделать.**

1. `require_relative '../lib/config/loader'`, `'../lib/routing/assembly'`.
2. Новый флаг: `--config PATH`, «Файл конфигурации (по умолчанию config/routing.yml)».
   `default_options`: `config_path: 'config/routing.yml'`.
3. Из `default_options` **убрать** `strategy: 'count_share'`. Ключ `:strategy` остаётся
   `nil`, пока не передан `--strategy`.
4. Загрузка конфига в `load_inputs` (или рядом с ним), с человекочитаемой ошибкой:

```ruby
def load_config(path)
  Config::Loader.load(path)
rescue RuntimeError => e   # Config::SchemaError наследует RuntimeError
  fail_with(e.message)
end
```

5. Стратегия строится через `Routing::Assembly.strategy(config: config, override:
   options[:strategy])`, слои — через `Routing::Assembly.layers(config: config)`. `KeyError`
   от обоих ловится и уходит в `fail_with(e.message)` — выход с кодом 1, а не трейс.
   Существующий `build_strategy`/`rescue KeyError` заменяется этим.
6. `Routing::Planner.new(..., fallback_provider: config.fallback_provider)` — конфиг
   определяет и fallback. Значение в файле уже `spacepayments`, поведение не меняется.
7. Обновить шапку `bin/route` (usage) и **шапку `config/routing.yml`**: убрать абзац «этот
   файл сейчас ни на что не влияет», написать, что файл читает `bin/route` на старте и что
   `--strategy` перекрывает ключ `strategy`. **Значения ключей в YAML не менять ни одного**
   — от них зависят числа регрессии.

**Инварианты.**

- Порядок и содержание выходных JSON при дефолтных аргументах меняться не должны: в
  `config/routing.yml` записано `strategy: count_share`, а хардкод был тем же самым.
- `spacepayments` остаётся fallback по допуску: значение берётся из конфига, но семантика
  `Planner` не трогается.
- В `lib/routing/` и `lib/execution/` не появляется чтения файлов: конфиг читает только
  `bin/route`.
- `layers: []` в боевом конфиге → прогон как раньше.

**Спеки** (дописать в `spec/bin/route_spec.rb`, стиль файла — `Open3.capture3` во временном
каталоге):

1. Прогон без аргументов, кроме очереди и `--out-dir`: код 0, оба файла на месте (уже есть,
   должен продолжать проходить).
2. Временный конфиг со `strategy: load` через `--config` → распределение
   `quickpay 8 / payflow 2 / vipay 0`.
3. Временный конфиг со `strategy: load` + `--strategy priority` → распределение
   `vipay 4 / payflow 3 / quickpay 3`, то есть CLI победил.
4. Временный конфиг со `strategy: нет_такой` → код выхода 1, stderr содержит
   `config/routing.yml` и список допустимых.
5. Временный конфиг с `layers: [conversion]` → код выхода 1, stderr упоминает слои.
6. `--config no/such/file.yml` → код выхода 1, внятное сообщение, не трейс.

Временные конфиги пишутся в `Dir.mktmpdir`. **Боевой `config/routing.yml` спеки не
модифицируют никогда** — иначе параллельный прогон и упавший спек оставят репозиторий в
изменённом состоянии.

**Критерий приёмки.**

```
make gate
make validate
```

`make validate` → `✅ Пройдено: 29`, `❌ Ошибок:   0`. Плюс `make determinism` →
`детерминизм: OK`.

---

### БРИФ W4 — доказательство «одна строка YAML меняет распределение»

**Контекст.** Критерий CFG-2 из `docs/TASKS.md`: «смена одной строки меняет распределение,
код не тронут». Нужен спек, который это проверяет не тавтологией («мы попросили другую
стратегию — получили другую стратегию»), а числами на публичной очереди.

**Файл.** Новый `spec/bin/config_switch_spec.rb`. Стиль — как `spec/bin/route_spec.rb`:
`Open3.capture3('ruby', bin_route, ...)`, временные каталоги, никаких правок репозитория.

**Как готовится конфиг.** Читаем `config/routing.yml`, заменяем **ровно одну строку**,
пишем во временный файл, передаём `--config`. Замена — `String#sub` по конкретной строке,
чтобы спек падал, если строка в YAML исчезла (это тоже сигнал).

**Сценарий 1 — переключение стратегии.** Строка `strategy: count_share` → `strategy: load`.

| | vipay | payflow | quickpay |
|---|---|---|---|
| `strategy: count_share` (как в репозитории) | 3 | 3 | 4 |
| `strategy: load` | 0 | 2 | 8 |

**Сценарий 2 — данные конфига, а не только имя стратегии.** Строка
`  - { from: 500, to: 50000, prefer: payflow }` → `  - { from: 500, to: 50000, prefer:
vipay }`, обе версии со `strategy: amount_range`.

| | vipay | payflow | quickpay | op_101 | `details` первой попытки op_101 |
|---|---|---|---|---|---|
| `prefer: payflow` | 3 | 4 | 3 | `payflow` | `amount_range: 15000, полоса за payflow, первый payflow, второй vipay` |
| `prefer: vipay` | 4 | 3 | 3 | `vipay` | `amount_range: 15000, полоса за vipay, первый vipay, второй payflow` |

Все четыре числа измерены прогоном, а не выведены. Сценарий 2 — главный: он падает, если
конфиг доехал только до выбора класса, а полосы остались дефолтными (пустыми). Проверять
обязательно **и** распределение, **и** подстроку `полоса за vipay` в `details` — распределение
совпало бы случайно при откате `AmountRange` к самозагрузке файла.

**Сценарий 3 — боевой конфиг непротиворечив** (отдельный быстрый пример, без запуска
процесса): загрузить `config/routing.yml` через `Config::Loader`, проверить, что
`config.strategy` входит в `Routing::Strategies.known`, а каждое имя из `config.layers`
входит в `Routing::Layers.known`. Ловит опечатку в боевом конфиге до часа стопкода.

**Инварианты.**

- Спек не пишет в репозиторий. Оригинальный `config/routing.yml` только читается.
- Числа фиксируются как константы в спеке с комментарием «измерено на
  `reference/data/operations_queue_10.json`, `--outcomes deterministic --seed 42`».
- Если появится W3b (источник исходов из конфига) — числа не поменяются: в YAML тот же
  `deterministic` и тот же `seed: 42`.

**Критерий приёмки.**

```
bundle exec rspec spec/bin/config_switch_spec.rb
```

0 падений, минимум 3 примера. Затем `make gate` и `make validate` — оба зелёные.

---

### БРИФ W5 — новая стратегия не требует правок ядра

**Контекст.** Критерий CFG-3 — «новая стратегия = файл + строка в конфиге, без правок
ядра». Сегодня это неправда: `bin/route` содержит шесть строк
`require_relative '../lib/routing/strategies/<имя>'`, и без седьмой строки новый файл никто
не загрузит.

**Файлы.**

1. `lib/routing/strategies.rb` — добавить автозагрузку:

```ruby
def load_all!
  Dir[File.expand_path('strategies/*.rb', __dir__)].sort.each do |path|
    require path
  end
  known
end
```

`sort` обязателен: порядок `Dir.glob` зависит от файловой системы, а недетерминированный
порядок регистрации — прямое нарушение инварианта детерминизма (`AGENTS.md`).
`strategies/base.rb` грузить безопасно (он ничего не регистрирует), исключать его не нужно,
но `known` его не увидит.

2. `bin/route` — удалить шесть `require_relative` конкретных стратегий, вызвать
   `Routing::Strategies.load_all!` один раз после `require_relative
   '../lib/routing/strategies'`. `require_relative '../lib/routing/planner'` остаётся:
   `Planner` тянет `count_share` сам как дефолт конструктора.

**Инварианты.**

- Имя файла = имя стратегии: `lib/routing/strategies/<name>.rb` регистрирует `'<name>'`. Все
  семь существующих файлов правилу подчиняются, проверить не изменяя их.
- Повторный `load_all!` не должен ронять процесс: `require` идемпотентен, повторной
  регистрации (и `ArgumentError` «strategy already registered») не происходит.
- Никаких `autoload`, никакого `require` внутри `rank`.

**Спеки** (`spec/routing/strategies_registry_spec.rb`):

1. После `Routing::Strategies.load_all!` — `known` **точно равен** отсортированному списку
   базовых имён файлов `lib/routing/strategies/*.rb` минус `base`. Именно равенство, не
   `include`: спек ловит и «файл добавили, а `register` забыли», и «файл-мусор остался в
   каталоге после демо».
2. `load_all!` вызванный дважды не бросает исключений и не меняет `known`.
3. `known` уже содержит все семь имён (регрессия к текущему состоянию).

**Критерий приёмки.**

```
make gate
make validate
```

Оба зелёные; в `bin/route` не осталось ни одного `require_relative` с путём
`lib/routing/strategies/`, кроме самого `strategies`.

---

### БРИФ W6 — README и одноминутное демо расширяемости (CFG-3)

**Контекст.** `README.md` в репозитории отсутствует. Критерий CFG-3: «документировано в
README, показывается на защите». README — это ещё и 3 балла техжюри за «понятен порядок
запуска».

**Файл 1 — `README.md` в корне.** Разделы, ровно в этом порядке, без воды:

1. **Что это.** Офлайн-движок роутинга выплат: вход — снапшот провайдеров и очередь, выход —
   `routing_decisions_test.json` и `routing_report_test.json` в корне репозитория. Ruby,
   без Rails, БД и сети. Нейросетей в коде нет — прямой запрет ТЗ.
2. **Как запустить.** `make install`, `make route`, `make deliver`, `make gate`,
   `make validate`, `make determinism` — по строке на цель, с указанием, что печатает
   успешный прогон (`✅ Пройдено: 29`, `❌ Ошибок: 0`).
3. **Раскладка каталогов** — короткая таблица из `AGENTS.md`, без пересказа кода.
4. **Конфигурация.** Полный текущий `config/routing.yml` и таблица «ключ → что делает →
   влияет ли сегодня». Честно, по факту кода:

   | ключ | что делает | статус |
   |---|---|---|
   | `strategy` | активная стратегия ранжирования | влияет |
   | `layers` | слои-модификаторы поверх стратегии | реестр пуст; непустой список = ошибка запуска, слои приезжают в Ф4 |
   | `amount_ranges` | полосы суммы для стратегии `amount_range` | влияет, когда `strategy: amount_range` |
   | `fallback_provider` | провайдер последней надежды | влияет |
   | `allocator.tie_break` | порядок разрешения ничьих | описывает поведение аллокатора, отдельно не читается |
   | `outcomes` | источник исходов и seed | *(влияет — если сделан W3b; иначе: значения продублированы дефолтами CLI)* |
   | `obligations`, `rate_limits` | финансовые обязательства и интенсивность | схема валидируется, поведение не подключено: полей `daily_turnover_min/max` и `requests_per_minute_limit` нет в `providers.json` |

   Врать в этой таблице нельзя: жюри читает конфиг и спрашивает по нему.
5. **Приоритет источников:** `--strategy` перекрывает `strategy` из YAML; путь к конфигу
   меняется флагом `--config`. Пример обеих команд.
6. **Демо «одна строка меняет распределение»** — две команды и таблица чисел из БРИФ W4
   (count_share 3/3/4 против load 0/2/8), с припиской, что валидатор организаторов остаётся
   зелёным в обоих случаях.
7. **Как добавить стратегию — три шага, без правок ядра.**
   1. Создать `lib/routing/strategies/<name>.rb`: наследник `Routing::Strategies::Base`,
      методы `rank(candidates, operation, state)` (возвращает перестановку кандидатов),
      `name`, `explain(ranked, operation, state)` (строка с числами), внизу файла
      `register('<name>', Klass)`. Нужны данные из конфига — добавить
      `def self.from_config(config)`.
   2. Написать `strategy: <name>` в `config/routing.yml`.
   3. Запустить `make validate`.
   Явно: `bin/route` править не нужно (каталог загружается целиком), реестр править не
   нужно, `Planner` не знает имён стратегий. Ограничения: `rank` возвращает **перестановку**
   допущенных — не добавляет и не удаляет провайдеров (`Planner` это проверяет и падает),
   не смотрит в будущие операции очереди, не использует `rand`/`Time.now`, сравнивает дроби
   перекрёстным умножением целых.
8. **Что мы сознательно не делаем** — три строки из `SCOPE.md` §5.

**Файл 2 — `docs/examples/reverse_priority.rb`.** Готовая демонстрационная стратегия на
~25 строк (`rank` — сортировка по убыванию `priority`, `name` = `'reverse_priority'`,
`explain` с числами `priority`). Лежит **вне** `lib/`, поэтому реестр её не видит и спек
«реестр = каталог» из W5 остаётся зелёным. Файл обязан быть чистым по rubocop.

**Файл 3 — `scripts/demo_new_strategy.sh`.** Скрипт на минуту защиты, рядом с существующим
`scripts/check_determinism.sh`:

1. копирует `docs/examples/reverse_priority.rb` в `lib/routing/strategies/`;
2. `trap` на `EXIT`, который удаляет копию при любом исходе — включая Ctrl+C и падение;
3. печатает `Routing::Strategies.known` до и после копирования (7 имён → 8);
4. гоняет `bin/route ... --strategy reverse_priority --out-dir <tmp>` и печатает
   распределение по `selected_provider`;
5. запускает `ruby reference/scripts/validate_10.rb <tmp>/routing_decisions_test.json` и
   печатает его хвост;
6. удаляет копию и печатает `known` снова — снова 7 имён;
7. завершается ненулевым кодом, если валидатор дал не 0 ошибок, или если после уборки в
   `lib/routing/strategies/` остался лишний файл.

**Инварианты.**

- Скрипт обязан оставлять `git status` чистым. Проверяется вручную сразу после прогона.
- Скрипт не входит в `make gate` (он временно пишет в `lib/`), запускается только руками.
- README не содержит обещаний, которых нет в коде. Каждая строка таблицы ключей — проверена
  чтением кода.

**Критерий приёмки.**

```
bash scripts/demo_new_strategy.sh
git status --porcelain
make gate
```

Первая команда: код выхода 0, в выводе видно 7 → 8 → 7 стратегий, распределение
`reverse_priority` и `❌ Ошибок:   0` от валидатора. Вторая: пустой вывод (кроме
заранее известных изменений рабочего дерева). Третья: зелёная.

---

### БРИФ W3b — источник исходов из конфига *(опциональный)*

**Берётся только после PASS по W4.** Ключ `outcomes` (`source: deterministic`, `seed: 42`)
сегодня в конфиге есть и не читается; те же значения продублированы в `default_options`
`bin/route`. Пока дубль совпадает, конфиг врёт безобидно — но именно про него будет вопрос
на защите после README.

**Что сделать.** В `bin/route`: `--outcomes` и `--seed` становятся переопределениями поверх
`config.outcomes['source']` и `config.outcomes['seed']`; из `default_options` соответствующие
хардкоды удаляются. Ключ `calibrate_from_history` **не подключать** — конверсии калибруются
всегда (`Strategies::Conversion` грузит историю сам), и в README он помечен как
неподключённый. Отдельно не менять `Strategies::Conversion`: его самозагрузка истории —
известный долг, но это файл Кирилла и другая задача.

**Спеки.** Дописать в `spec/bin/route_spec.rb`: временный конфиг с `outcomes: {source:
always_ok, seed: 42}` → все `simulated_result` равны `approved`; тот же конфиг плюс
`--outcomes deterministic` → появляются не-`approved` (CLI сильнее).

**Критерий приёмки.**

```
bundle exec bin/route reference/data/operations_queue_10.json --out-dir /tmp/w3b_after
diff /tmp/w3b_before/routing_decisions_test.json /tmp/w3b_after/routing_decisions_test.json
make gate && make validate
```

`diff` пуст: прогон до правки и после совпадает побайтово (`/tmp/w3b_before` снимается
до начала работы). Любое расхождение — значит из конфига приехало не то, что было
захардкожено, и пакет откатывается.

---

### БРИФ W7 — гейт зоны

Прогнать §6 целиком, приложить вывод дословно. Кода не писать. Если что-то красное — это
FAIL пакета, к которому относится проверка, а не повод править на месте.

---

## 6. Гейт зоны Вовы в Ф3

Зона закрыта, когда одновременно:

1. `make gate` — rspec 0 падений, rubocop 0 замечаний, `make no-random` чист.
2. `make validate` — `✅ Пройдено: 29`, `❌ Ошибок:   0`, `⚠️ Предупр.: 0`.
3. `make determinism` — `детерминизм: OK`.
4. Семь стратегий, переключаемых **конфигом**, дают семь распределений из таблицы §0 и на
   каждой валидатор зелёный. Одна команда:

```
for s in amount_range conversion count_share load obligations priority volume_share; do \
  bundle exec bin/route reference/data/operations_queue_10.json --out-dir /tmp/s_$s --strategy $s >/dev/null && \
  printf '%-14s ' "$s" && \
  ruby -rjson -e 'd=JSON.parse(File.read(ARGV[0])); h=Hash.new(0); d.each { |x| h[x["selected_provider"]] += 1 }; print h.sort.map { |k, v| "#{k}=#{v}" }.join(" "), "  "' /tmp/s_$s/routing_decisions_test.json && \
  ruby reference/scripts/validate_10.rb /tmp/s_$s/routing_decisions_test.json | grep -E 'Ошибок'; done
```

Ожидается ровно семь строк, в каждой `❌ Ошибок:   0`, числа совпадают с §0.

5. `bundle exec rspec spec/bin/config_switch_spec.rb` — зелёный, включая сценарий 2 с
   `полоса за vipay` в `details`.
6. `bash scripts/demo_new_strategy.sh` → код 0, `git status --porcelain` после него пуст.
7. `README.md` существует, содержит раздел «как добавить стратегию» и таблицу статусов
   ключей конфига без обещаний, которых нет в коде.
8. `spec/support/shared/strategy_contract.rb`, `spec/config/loader_spec.rb` и
   `spec/routing/strategies/*_spec.rb` **не изменены** — правки Ф3 не должны требовать
   переписывания спеков Кирилла.

Пункты 4–7 валидатор организаторов не проверяет вообще: он останется зелёным при полностью
мёртвом конфиге. Гейт зоны шире гейта организаторов ровно по этой причине.

---

## 7. Что может сломаться молча

| Что | Почему тихо | Чем ловится |
|---|---|---|
| Конфиг прочитан, стратегия построена по имени, но `amount_ranges` не доехали: `AmountRange` работает с пустыми полосами | Стратегия вырождается в порядок по `priority`, исключений нет, валидатор зелёный, распределение правдоподобное | W4 сценарий 2: `details` op_101 обязан содержать `полоса за payflow` / `полоса за vipay`, плюс распределение 3/4/3 против 4/3/3 |
| `AmountRange` откатили к самозагрузке `config/routing.yml` | Всё «работает», но конфиг снова читается мимо пайплайна, а `--config` на полосы не влияет | W1 спек «`const_defined?(:CONFIG_PATH)` == false» + W4 сценарий 2 с временным конфигом (боевой YAML не менялся, значит самозагрузка дала бы старые числа) |
| Непустой `layers` молча игнорируется | На защите пишут `layers: [conversion]`, ничего не меняется, никто не замечает — фича выглядит существующей | W2 спек `layers(['conversion']) → KeyError` + W3 спек «код выхода 1, stderr про слои» |
| `layers: [conversion]` подхватил `Strategies::Conversion` вместо слоя | Возвращает перестановку, не падает, выглядит как работающий слой; в Ф4 обнаружится, что слоя нет | W2 спек «реестры раздельные»: `Layers.known == []`, `Layers.build('conversion')` бросает |
| CLI и YAML поменялись приоритетом местами | `make validate` зелёный в обоих случаях; расходится только то, что видит жюри на демо | W2 спеки 2–3 и W3 спек 3: конфиг `load` + `--strategy priority` → 4/3/3, не 0/2/8 |
| `default_options` сохранил `strategy: 'count_share'` | Флаг «передан всегда», YAML никогда не побеждает, конфиг мёртв при зелёном гейте | W3 спек 2: временный конфиг `strategy: load` без флага → 0/2/8 |
| `Dir.glob` без `sort` в `load_all!` | Порядок регистрации зависит от файловой системы; на другой машине сообщения и `REGISTRY` в другом порядке — невоспроизводимая цифра на защите | W5 спек «`known` == отсортированные имена файлов» + ревью: `sort` в одной строке с `Dir[]` |
| Новая стратегия добавлена файлом, но `register` забыт | `--strategy new` падает «unknown strategy» только при попытке запуска, спеки молчат | W5 спек на **равенство** `known` и списка файлов каталога |
| Демо-скрипт упал посередине и оставил копию в `lib/routing/strategies/` | Репозиторий грязный, `make gate` может пройти, а на защите лишняя восьмая стратегия | `trap EXIT` в скрипте + W5 спек равенства (лишний файл ломает `known`) + `git status --porcelain` в гейте |
| Схема конфига валидна, но имя стратегии — опечатка (`count_shar`) | Обнаружится только при запуске, потенциально в час стопкода | W4 сценарий 3: спек на боевой `config/routing.yml`, `config.strategy ∈ Strategies.known` |
| README расходится с кодом (обещает `obligations`/`rate_limits`) | Документ спеком не проверяется; ловится только вопросом жюри | Таблица статусов ключей в README пишется по коду, C-3 зафиксировано в плане; проверяется на ревью Вовой перед защитой |
| `fallback_provider` из конфига разъехался со `spacepayments` | `Planner` перестанет исключать его из кандидатов — spacepayments начнёт выигрывать обычные операции, а валидатор считает его допустимым **всегда** и промолчит | `make validate` зелёный не поможет; ловит W3 спек 1 (распределение по умолчанию 3/3/4, `spacepayments` не появляется) и W4 сценарий 3 |

---

## 8. Порядок исполнения и риски

1. **W1** — полчаса, снимает единственный обходной путь (`AmountRange` читает файл сам).
   Без него W3 нечего доставлять в стратегию.
2. **W2** — полчаса, чистый юнит без ввода-вывода, готовит врезку.
3. **W3** — критический путь фазы. После него `make validate` обязан остаться зелёным; если
   он красный, виноват композиционный корень, а не стратегии: у каждой из них свой спек.
4. **W4** — доказательство критерия CFG-2. Отдельным пакетом от W3 намеренно: врезка и её
   доказательство не должны падать одним FAIL.
5. **W5** — независим от W2/W3/W4, можно отдать сразу после W1, если кодер свободен.
6. **W6** — только после W4 и W5: README ссылается на числа W4 и на автозагрузку W5.
7. **W3b** — опционально, отдельным коммитом, после W4.
8. **W7** — только после PASS по W4 и W6.

**Риски.**

- *Правка в файле Кирилла (W1, `amount_range.rb`).* Митигируется тем, что публичный
  контракт `new(ranges:)` не меняется и `spec/routing/strategies/amount_range_spec.rb` не
  трогается. Уведомление Кириллу до мержа обязательно (`OWNERSHIP.md` §9).
- *Числа §0 привязаны к `OutcomeSource::Deterministic` с `seed: 42`.* Любая правка seed,
  конверсий или `reference/data/*` сдвинет всю таблицу и уронит W4. Если это произойдёт —
  таблица §0 **перемеряется**, а не подгоняется под спек.
- *C-3 (декоративные `obligations`/`rate_limits`) остаётся открытым.* На защите это вопрос
  «стратегия `obligations` у вас что-нибудь делает?». Честный ответ подготовлен в README;
  вариант B — отдельная задача после Ф3, решение принимает человек, не кодер.
- *Соблазн доделать слои «раз уж мы здесь».* Слои — X-1, X-2, X-3 из Ф4. В Ф3 они не
  делаются даже частично: применение слоёв в `Planner` без единого зарегистрированного слоя
  непроверяемо, а непроверяемый код в решающем пути — худшее, что можно занести в фазу,
  закрывающую 72 из 140 баллов.

---

## 9. Список пакетов (сводка)

| ID | Пакет | Одна команда приёмки |
|---|---|---|
| W1 | `Strategies.build(name, config:)`, протокол `from_config`, `AmountRange` без чтения файла | `make gate` |
| W2 | `Routing::Layers` (пустой реестр) + `Routing::Assembly` | `make gate` |
| W3 | `bin/route`: `--config`, конфиг на старте, снятие хардкода стратегии | `make validate` |
| W4 | Спек «одна строка YAML меняет распределение» (2 сценария + боевой конфиг) | `bundle exec rspec spec/bin/config_switch_spec.rb` |
| W5 | Автозагрузка каталога стратегий, спек «реестр = каталог» | `make gate` |
| W6 | `README.md` + `scripts/demo_new_strategy.sh` + `docs/examples/reverse_priority.rb` | `bash scripts/demo_new_strategy.sh` |
| W3b | *(опц.)* `outcomes` из конфига, побайтовое совпадение вывода | `diff` двух прогонов + `make validate` |
| W7 | Гейт зоны | §6 целиком |
