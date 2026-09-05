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

cascade:
  exhausted: last_candidate
  on_timeout: stop

fallback_provider: spacepayments

comparison:
  - { name: round_robin,        strategy: round_robin, layers: [] }
  - { name: count_share,        strategy: count_share, layers: [] }
  - { name: count_share+layers, strategy: count_share, layers: [budget_headroom, share_ceiling] }
```

Файл читает `bin/route` на старте, ровно один раз, и передаёт объектом
`Config::RoutingConfig` в `Routing::Assembly`. Ни `Planner`, ни стратегии, ни
`Executor` файловой системы не касаются.

Схему ключей валидирует `Config::Loader` (`lib/config/loader.rb`);
битый конфиг даёт сообщение и код выхода 1, а не трейс. Валидность схемы и
влияние на поведение — разные вещи, поэтому таблица ниже честно разделяет их.

| Ключ                               | Что делает | Влияет сегодня |
|------------------------------------|---|---|
| `strategy`                         | активная стратегия ранжирования каскада | **да** |
| `layers`                           | лексикографические мягкие модификаторы поверх стратегии | **да**, если перечислены `budget_headroom` и/или `share_ceiling`; боевой конфиг оставляет `[]` |
| `goals`                            | пороги слоёв | **да**, когда соответствующий слой включён |
| `strategy_selection`               | правила выбора стратегии для текущей операции | **да**, если содержит непустой `rules` |
| ` amount_ranges`                   | полосы суммы для стратегии `amount_range` | **да**, когда `strategy: amount_range` |
| `fallback_provider`                | провайдер последней надежды (fallback по допуску) | **да**: имя уходит в `Routing::Planner` |
| `outcomes.source`, `outcomes.seed` | источник симулированных исходов и seed | **да**; CLI-флаги сильнее YAML |
| `outcomes.calibrate_from_history`  | брать конверсии исходов из `operations_history.csv` | **да** |
| `obligations`                      | целевые дневные обороты провайдеров | на public-снапшоте не применяются; CLI один раз печатает предупреждение о недостающих полях |
| `rate_limits`                      | ограничение интенсивности (запросов в минуту) | на public-снапшоте не применяются; CLI один раз печатает предупреждение о недостающем поле |
| `cascade.exhausted`                | что делать, когда каскад исчерпан обычными отказами | **да**: `last_candidate` (дефолт, сегодняшнее поведение) или `fallback_provider` (буквальное ТЗ — доп. попытка на spacepayments) |
| `cascade.on_timeout`               | что делать при таймауте (`expired`) кандидата | **да**: `stop` (дефолт — резерв держится, каскад не продолжается) или `continue` (резерв держится и каскад идёт дальше — двойная попытка, см. `Execution::PendingResolver`) |
| `comparison`                       | офлайн-сравнение вариантов (стратегия+слои) на той же очереди | секцию отчёта и таблицу в консоли включает; на принятие решений не влияет никогда |

Обе альтернативные ветки `cascade` доступны переключателем, не удалением кода:
ТЗ читается буквально («при отказе/таймауте — исключить провайдера и выбрать
следующего, если пул пуст — fallback на spacepayments»), а дефолт остаётся
сегодняшним поведением побайтово. Демонстрационный конфиг с обеими
альтернативными ветками разом — `config/examples/tz_literal.yml`.

Следствие для `obligations`: стратегия `obligations` на публичном снапшоте
вырождается — у всех провайдеров `min`/`max` равны `nil`, и порядок
определяется именем. Это известное ограничение данных, а не скрытая логика.

### Слои и селектор

Слои не расширяют множество допущенных: они только переупорядочивают его по кортежу
отклонений, где первый в списке слой старше. `budget_headroom` использует
`ψ = 1 − exp(−(1 − approved / limit))`; чем меньше ψ, тем ближе провайдер к дневному
лимиту. Это BALANCE-подход из [Mehta et al., *AdWords and Generalized Online Matching*,
FOCS 2005](https://doi.org/10.1109/FOCS.2005.21).

Боевой конфиг намеренно содержит `layers: []`: включение ψ меняет целевое распределение,
и решение о такой политике должен принять человек. Примеры можно запустить отдельно:

```sh
bundle exec bin/route reference/data/operations_queue_10.json --config config/examples/adwords.yml --out-dir /tmp/adwords
bundle exec bin/route reference/data/operations_queue_10.json --config config/examples/goals_reversed.yml --out-dir /tmp/goals-reversed
bundle exec bin/route reference/data/operations_queue_10.json --config config/examples/selector.yml --out-dir /tmp/selector
```

Последний пример выбирает стратегию на текущей операции правилами `amount_gte`, `amount_lt`,
`bank_in` и `eligible_count_lte`; ML в этом процессе не используется.

### Сравнение стратегий (офлайн)

`docs/SCOPE.md` §4.7 обещает сравнение стратегий на одной очереди — ключ `comparison` в
конфиге (см. YAML выше) закрывает это числами, а не обещанием. Каждый вариант — такой же
**онлайн**-проход по той же очереди на своём состоянии (см. `Offline::Comparison`), результат
идёт только в консоль и в секцию `comparison` отчёта, никогда в принятие решений
(`spec/offline/isolation_spec.rb`, `spec/offline/comparison_spec.rb`). Фактический прогон
(seed 42, `reference/data/operations_queue_10.json`, боевой снапшот):

| вариант | доставлено | fallback | ретраи | откл. от достижимого, п.п. | откл. от цели, п.п. |
|---|---|---|---|---|---|
| `round_robin` (baseline для сравнения, П3) | 10 | 0 | 0 | 40.0 | 45.0 |
| `count_share` (боевая стратегия) | 10 | 0 | 0 | 0.0 | 5.0 |
| `count_share` + `budget_headroom`/`share_ceiling` | 10 | 0 | 0 | 20.0 | 25.0 |

Правая колонка (откл. от паспортных целей 40/35/25) сопоставима с `benchmark.max_deviation_pp`
из отчёта; средняя строка — это и есть боевой прогон, числа совпадают побайтово с
`distribution`/`routing_decisions_test.json` (спек `spec/offline/comparison_spec.rb` это
проверяет, а не глазами). Включение слоёв поверх `count_share` **ухудшает** оба отклонения
(0.0 → 20.0 п.п. от достижимого, 5.0 → 25.0 п.п. от цели) на этой очереди: `layers: []` в
боевом конфиге — не забытая функциональность, а измеренное решение (развилка Ф-5,
`docs/plans/P6/README.md`).

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
| `strategy: count_share` (как в репозитории) | 3 | 3 | 4 |
| `strategy: load` | 1 | 9 | 0 |

Числа измерены на `reference/data/operations_queue_10.json` с дефолтами
`bin/route` (`--outcomes deterministic --seed 42`). Валидатор организаторов на
обоих прогонах остаётся зелёным: `❌ Ошибок:   0`. Автоматически это проверяет
`spec/bin/config_switch_spec.rb`.

Полный набор стратегий на той же очереди, семь исходных из Ф3 (`✅ 29 / ❌ 0`;
восьмая, `round_robin`, — не кандидат на боевую роль, а baseline для офлайн-сравнения,
см. §4 «Сравнение стратегий»):

| `strategy` | payflow | quickpay | vipay |
|---|---|---|---|
| `amount_range` | 3 | 4 | 3 |
| `conversion` | 1 | 5 | 4 |
| `count_share` | 3 | 3 | 4 |
| `load` | 1 | 9 | 0 |
| `obligations` | 3 | 7 | 0 |
| `priority` | 3 | 3 | 4 |
| `volume_share` | 3 | 3 | 4 |

### Демо ретрая: каскад на seed 1

На боевом seed 42 публичная очередь не содержит ни одного `rejected`: жюри не увидит
ни повторной попытки, ни причины `next_in_cascade` — а это баллы за «последовательность
действий при отказе». Один и тот же вход, другой seed источника исходов, показывает
каскад детерминированно:

```
bundle exec bin/route reference/data/operations_queue_10.json --seed 1 --out-dir /tmp/retry
```

`op_110` на seed 1 получает `payflow` (отказ, `rejected`) первой попыткой и `quickpay`
(таймаут, `expired`) второй:

```json
{
  "operation_id": "op_110",
  "selected_provider": "quickpay",
  "attempts": [
    { "provider": "vipay", "decision": "skipped", "reason": "bank_not_in_list", "details": "..." },
    { "provider": "payflow", "decision": "selected", "reason": "best_target_adherence",
      "attempt_no": 1, "result": "rejected" },
    { "provider": "quickpay", "decision": "selected", "reason": "next_in_cascade",
      "details": "payflow отказал на попытке 1, попытка 2", "attempt_no": 2, "result": "expired" }
  ],
  "simulated_result": "expired"
}
```

`quickpay` входит в множество допустимых для `op_110`
(`reference/data/reference_decisions.json`, `eligible_providers.op_110`), и валидатор
на этом прогоне остаётся `❌ Ошибок: 0`. Seed зафиксирован константой в
`spec/bin/retry_demo_spec.rb` — если число в README и в спеке разойдётся, спек
провалится первым.

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
рост реестра на единицу (после П3 базовый размер — восемь: семь исходных плюс
`round_robin`, baseline для сравнения из §4), гоняет `bin/route` с конфигом, где
заменена одна строка, печатает распределение и вердикт валидатора, убирает
копию и показывает реестр обратно к восьми. Скрипт считает размер реестра
динамически (`Routing::Strategies.load_all!.size`), поэтому само число в его
выводе не расходится с фактом даже при следующей новой стратегии; расходится
только текст соседнего комментария в самом скрипте — это отдельная, не
затронутая здесь мелочь. Скрипт временно пишет в `lib/`, поэтому в `make gate`
он не входит и запускается руками; копия удаляется при любом исходе, включая
Ctrl+C.

## 8. Fallback и каскад: две трактовки, обе доступны

ТЗ (`reference/TZ.md:185`, дословно):

> Fallback: при отказе/таймауте - исключить провайдера из пула и выбрать следующего.
> Если пул пуст - fallback на spacepayments (self-provider).

Наше поведение по умолчанию расходится с буквой ТЗ дважды, и оба расхождения
осознанные:

1. **Исчерпание каскада.** Когда все реальные кандидаты отказали (`rejected`), мы
   НЕ подключаем `spacepayments` — `selected_provider` остаётся последним реальным
   кандидатом, с `result: rejected`. `spacepayments` у нас — fallback **по допуску**
   (ни один внешний провайдер не прошёл hard-constraints), а не по исходу отказа.
2. **Таймаут не продолжает каскад.** `expired` останавливает исполнение: резерв
   держится (`State#hold`), операция считается условно успешной, следующий кандидат
   не пробуется. Поздний ответ провайдера применяет
   `lib/execution/pending_resolver.rb` как компенсирующую дельту «с текущего момента».

Три опоры этого дефолта, с адресами:

- `reference/QA_TRANSCRIPT.txt:84` — организаторы дословно: «если hard-фильтр никто
  не прошёл, то там есть fallback на дефолтный провайдер space payments» — это про
  допуск, не про исход, и совпадает с нашим инвариантом (1);
- `reference/QA_TRANSCRIPT.txt:201` — организаторы про таймаут дословно: «когда мы
  получаем тайм-аут, мы точно не знаем, что у нас там произошло. Поэтому пока что мы
  считаем, что у нас как бы всё хорошо прошло» — прямая опора инварианта (2);
- `reference/data/reference_decisions.json` — четыре эталонных кейса (`op_103`,
  `op_104`, `op_107`, `op_108`) требуют конкретного `selected_provider`, а не
  `spacepayments`, при том что у каждого ровно один допустимый внешний провайдер —
  наше поведение с этим не расходится.

**Обе трактовки доступны переключателем, а не только нашей.** Ключ `cascade` в
`config/routing.yml` (см. §4):

```yaml
cascade:
  exhausted: last_candidate   # дефолт: как выше, п. 1
  on_timeout: stop            # дефолт: как выше, п. 2
```

`exhausted: fallback_provider` — буквальное ТЗ: сверх исчерпанного каскада ещё одна
попытка на `spacepayments`. `on_timeout: continue` — таймаут не останавливает каскад:
резерв на первом провайдере всё равно держится (инвариант резерва не нарушается), но
исполнение идёт к следующему кандидату. Демонстрационный конфиг с обеими
альтернативными ветками разом — `config/examples/tz_literal.yml`:

```
bundle exec bin/route reference/data/operations_queue_10.json --config config/examples/tz_literal.yml --out-dir /tmp/tz-literal
```

**Цена буквальной ветки — числом, а не предположением.** Замер на публичной очереди,
все четыре комбинации `exhausted`×`on_timeout` (`docs/plans/P6/P7_настраиваемый_fallback.md`,
раздел «Замеры»): валидатор организаторов даёт `Пройдено: 29, Ошибок: 0, Предупр.: 0` во
**всех** четырёх, и `routing_decisions_test.json` во всех четырёх побайтово идентичен.
Цена буквальной ветки на seed 42 — ровно ноль, но это свойство данных этой очереди
(`op_103`/`op_104` дают `expired` на единственном кандидате `quickpay`, поэтому
`continue` не находит, к кому продолжать, а `rejected`-исчерпание на этой очереди не
возникает вовсе), а не гарантия кода: на другой очереди с настоящим
`rejected`-исчерпанием или с `expired` не на последнем кандидате обе ветки дадут другой
результат по конструкции. Поэтому боевой конфиг держит дефолт, а не буквальную ветку —
переключатель существует, но не включён.

**Риск режима `on_timeout: continue`.** В этом режиме резерв первого провайдера и
попытка на втором существуют одновременно — двойная выплата в модели. Мы не
дублируем выплату при таймауте в режиме по умолчанию: держим резерв и ждём
статус-чек, как ответили организаторы в Q&A; буквальный режим ТЗ доступен ключом
конфига, и мы показываем, чем именно за него платим — риском двойной отправки.

## 9. Почему у отказавшего провайдера `decision: "selected"`

В `routing_decisions_test.json` попытка, закончившаяся отказом (`rejected`) или
таймаутом (`expired`), несёт `"decision": "selected"`, а не что-то вроде `"failed"`.
Это не наша путаница, а контракт схемы валидатора организаторов:
`reference/scripts/validate_10.rb:62-64` (`unless %w[selected skipped].include?(attempt['decision'])`)
принимает ровно два значения поля `decision` — `selected` и `skipped` — и любое третье
считает ошибкой структуры.

Наша семантика неудачной реальной попытки кодируется двумя ДОПОЛНИТЕЛЬНЫМИ полями,
которые валидатор не проверяет и молча пропускает, а человек читает:

- `result` — фактический исход попытки (`approved` / `rejected` / `expired`);
- `attempt_no` — порядковый номер попытки в каскаде.

`decision: skipped` остаётся только за электронным отсевом (hard-constraints) —
кандидатами, до которых каскад вообще не дошёл. `decision: selected` — за любой
РЕАЛЬНОЙ попыткой, независимо от того, чем она закончилась. Один финальный
`selected_provider` операции может иметь несколько `selected`-попыток подряд — это и
есть каскад (см. демо ретрая, §6).

## 10. Два отклонения — и почему они разные

Отчёт (`routing_report_test.json`) несёт два разных числа с похожими именами, и оба —
не ошибка задвоения:

- `distribution.<provider>.deviation_pp` — отклонение факта от **достижимой** доли.
  Достижимая доля (`Routing::Achievable`, `lib/routing/achievable.rb`) — это потолок
  «как могло бы быть» на множестве, допустимом по исходному снапшоту, с учётом
  физических ограничений конкретной очереди (единственный допустимый провайдер,
  дневной лимит) и квантования: на десяти заявках доля меняется шагом 10 п.п., и в
  35% попасть нельзя в принципе — расхождение цель/достижимое здесь арифметический
  пол очереди, а не промах движка;
- `benchmark.max_deviation_pp` (внутри `offline_bound`/`our_online_result`) —
  отклонение офлайн-эталона (`Offline::Oracle`, жадный старт плюс локальные
  улучшения) от **паспортных** целей 40/35/25 напрямую, без поправки на
  достижимость: эталон меряется той же линейкой, что и цель, а не потолком.

Фактический прогон (seed 42, боевой конфиг): `distribution.*.deviation_pp` по модулю
— максимум **0.0** п.п. (движок точно на достижимом потолке); `benchmark.max_deviation_pp`
— **5.0** п.п. (потолок ниже паспортной цели ровно на столько же). Если жюри спросит
«а какое из двух настоящее» — ответ здесь: оба настоящие, просто про разное. `0.0`
меряет качество движка при данных ограничениях очереди — движок не мог сделать лучше.
`5.0` меряет цену недостижимости самих целей — сколько теряет паспортная цель 40/35/25
из-за того, что на этой очереди её физически нельзя достичь (см. также `comparison` в
§4: колонка «откл. от цели» в таблице сравнения — то же самое число для других
вариантов, сопоставимое именно с `benchmark.max_deviation_pp`, а не с
`distribution.deviation_pp`).

## 11. Алгоритмы и источники

| Алгоритм | Источник | Где в коде |
|---|---|---|
| Метод Сент-Лагю (дивизорный аллокатор долей) | Balinski, Young. *Fair Representation: Meeting the Ideal of One Man, One Vote*, 2-е изд., Brookings, 2001 | `lib/routing/strategies/count_share.rb` (дивизор `2×count+1` — классическая последовательность Сент-Лагю), `lib/routing/share_ledger.rb` |
| Deficit Round Robin | Shreedhar, Varghese. *Efficient Fair Queueing Using Deficit Round Robin*, IEEE/ACM Transactions on Networking 4(3), 1996, doi:10.1109/90.502236 | `lib/routing/strategies/volume_share.rb` (долговой/дефицитный аллокатор по объёму), `lib/routing/strategies/round_robin.rb` (вырожденный случай DRR — равные веса, чистая ротация) |
| AdWords / BALANCE | Mehta, Saberi, Vazirani, Vazirani. *AdWords and Generalized Online Matching*, FOCS 2005, doi:10.1109/FOCS.2005.21 | `lib/routing/layers/budget_headroom.rb` (`ψ = 1 − exp(−(1 − approved/limit))`) |
| Лексикографическое goal programming | Charnes, Cooper. *Management Models and Industrial Applications of Linear Programming*, Wiley, 1961; Ignizio. *Generalized goal programming*, Computers & Operations Research 10(4), 1983 | `lib/routing/layer_stack.rb` (сортировка по кортежу отклонений слоёв, первый слой старше — преемптивный приоритет), `lib/routing/layers/share_ceiling.rb` |

## 12. HTTP-сервис (preview)

Параллельно к CLI ведётся минимальный HTTP-слой поверх того же ядра: потоковая
обработка операций одна-за-одной, глобальное in-memory состояние провайдеров,
живая аналитика из SQLite. CLI остаётся главной точкой входа и валидатором
организаторов не трогается — сервис нужен для демо и параллельной интеграции.

**Что уже есть (Stage 1 — контракт и UI):**

- **`docs/openapi.yaml`** — OpenAPI 3.0.3, 12 путей, 23 схемы. Источник правды
  для реализации и клиентов.
- **`public/swagger/`** — Swagger UI (swagger-ui-dist 5.32.15) с двойным режимом
  загрузки спеки: `file://` → относительный путь к YAML, `http://` → `/openapi.yaml`.

**Как посмотреть API прямо сейчас (сервер не нужен):**

```
xdg-open public/swagger/index.html   # или open, или просто в браузере
```

UI подхватывает спеку из `public/swagger/openapi-spec.js` — это сгенерированная
из `docs/openapi.yaml` встроенная копия (нужна, потому что Chrome блокирует XHR
в `file://` к соседним файлам). После правки `docs/openapi.yaml` пересобрать:

```
make openapi-embed
```

Через query-string `?spec=<url>` можно указать другую спеку (например, версию
для live-сервиса: `?spec=/openapi.yaml`).

**Другие таргеты** (`Makefile`):

```
make openapi-check                   # синтаксическая валидация docs/openapi.yaml
make openapi-embed                   # openapi-check + regenerate public/swagger/openapi-spec.js
make install-swagger-ui              # переливает assets, наш index.html и initializer.js остаются нетронутыми
```

**Что будет во втором этапе (после аппрува контракта):**

- Sinatra + Puma (workers=1, threads=1), Rack-entry `config.ru`, launcher `bin/serve`.
- `lib/api/{app,gateway,decisions_repo,stream_report_builder,validators,errors,serializers}.rb`.
- SQLite (`data/decisions.db`, WAL), нормализованная схема `decisions` + `attempts`,
  настраиваемый retention (дефолт 24ч), on-write чистка.
- `config/service.yml` — port, db_path, retention_hours.
- RSpec-набор `spec/api/**` с `:memory:` SQLite.
- End-to-end verification: `scripts/compare_batch_vs_cli.sh` — байт-в-байт
  сверка `/operations/batch` с `bin/route` на одной очереди.

Ядро (`lib/routing/**`, `lib/execution/**`, `lib/state/**`) в HTTP-слое не
меняется ни на строку — инварианты из CLAUDE.md сохраняются.

## 13. Что мы сознательно не делаем

- **Нейросети, ML, предсказание успеха** — прямой запрет ТЗ, дисквалификация.
- **Rails, БД, очереди, Sidekiq, Redis** — вход и выход это файлы, веб-слой
  баллов не даёт.
- **Единый «smart score» из десяти слагаемых** — необъяснимо, а объяснимость
  решений оценивается отдельно.

Полный список — `docs/SCOPE.md` §5.
