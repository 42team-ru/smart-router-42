<div align="center">

# smart-routing-42

**Движок умного роутинга платёжных выплат**

Выбирает провайдера для каждой выплаты с учётом жёстких ограничений и целевых
долей трафика, объясняет каждое решение числами и переходит к следующему
кандидату при отказе.

[![check](https://github.com/42team-ru/smart-router-42-hackgenesis/actions/workflows/tests.yml/badge.svg)](https://github.com/42team-ru/smart-router-42/actions/workflows/tests.yml)
![Ruby 3.3](https://img.shields.io/badge/Ruby-3.3-CC342D?logo=ruby&logoColor=white)
![валидатор 29/29](https://img.shields.io/badge/валидатор-29%2F29-2ea44f)
![детерминизм](https://img.shields.io/badge/детерминизм-побайтовый-2ea44f)

[Быстрый старт](#быстрый-старт) · [Как устроено](#как-устроено) · [Конфигурация](#конфигурация) · [Демо](#демо) · [Документация](#документация)

Хакатон **HackGenesis 2026** · компания **AUROSPACE Holding**

</div>

---

## Что делает

На входе — снапшот платёжных провайдеров и очередь заявок на выплату.
На выходе — два файла:

<table>
<tr><td width="50%" valign="top">

**`routing_decisions_test.json`**

Решение по каждой заявке: выбранный провайдер, все рассмотренные кандидаты,
причина каждого отсева.

</td><td width="50%" valign="top">

**`routing_report_test.json`**

Аналитика прогона: распределение против целей, причины отклонений, утилизация
лимитов, рекомендации.

</td></tr>
</table>

Каждое решение объяснимо: в `details` всегда конкретное сравнение
`52000 > limit_amount_max 50000`, а не «не подошёл».

```json
{
  "operation_id": "op_106",
  "selected_provider": "vipay",
  "attempts": [
    { "provider": "payflow", "decision": "skipped",
      "reason": "amount_exceeds_limit", "details": "52000 > limit_amount_max 50000" },
    { "provider": "vipay", "decision": "selected", "reason": "best_target_adherence",
      "details": "count_share: vipay 4000/5=800 против quickpay 2500/5=500",
      "attempt_no": 1, "result": "approved" }
  ],
  "simulated_result": "approved",
  "latency_sec": 38
}
```

---

## Быстрый старт

```bash
make install     # bundle install
make validate    # прогон + валидатор организаторов
```

```
✅ Пройдено: 29
❌ Ошибок:   0
⚠️  Предупр.: 0
```

<details>
<summary><b>Все команды</b></summary>

<br>

| Команда | Что делает |
|---|---|
| `make route` | прогон на публичной очереди, выход в `out/` |
| `make deliver` | тот же прогон, выход в корень репозитория |
| `make check` | `rspec` + `rubocop` + проверка отсутствия случайности |
| `make validate` | прогон + валидатор организаторов |
| `make determinism` | два прогона подряд и побайтовый `diff` |
| `make gen LEVEL=m` | сгенерировать синтетическую нагрузку |
| `make bench LEVEL=m` | стресс-прогон ядра с проверкой корректности |
| `make bench-configs` | сравнить конфигурации между собой |

Напрямую:

```bash
bundle exec bin/route <queue.json> [--out-dir DIR] [--providers PATH]
                      [--config PATH] [--strategy NAME]
                      [--outcomes NAME] [--seed SEED] [--script PATH]
                      [--set KEY=VALUE]
```

</details>

---

## Как устроено

```
заявка ──▶ допуск ──▶ стратегия ──▶ слои ──▶ каскад ──▶ попытка ──▶ запись
           8 проверок   ранжирует    двигают            approved
                                     порядок            rejected → следующий
                                                        expired  → статус-чек
```

**Допуск** отвечает «можно ли отдать заявку этому провайдеру», **стратегия** —
«кого из допущенных предпочесть». Стратегия не вправе вернуть отсечённого:
это проверяется на каждом плане.

**Восемь стратегий**, переключаются строкой в конфиге:

`count_share` · `volume_share` · `priority` · `amount_range` · `conversion` · `load` · `obligations` · `round_robin`

**Детерминизм.** Два прогона на одном входе дают побайтово одинаковый выход.
Исход попытки — не `rand`, а `SHA256(seed:операция:провайдер:попытка)`.
В решающем пути запрещены `rand`, `shuffle`, `sample` и обращения к текущему
времени — проверяется статически на каждом прогоне `make check`.

> Устройство модулей, контракты, форматы и инварианты —
> **[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)**

---

## Конфигурация

Всё поведение задаётся `config/routing.yml` — без единой правки кода:

```yaml
strategy: count_share
layers: []                       # budget_headroom, share_ceiling
outcomes:
  source: always_ok              # боевой; deterministic — модель исходов по истории
  seed: 42
  calibrate_from_history: true
cascade:
  exhausted: last_candidate      # или fallback_provider
  on_timeout: stop               # или continue
fallback_provider: spacepayments
```

Приоритет источников: **флаг CLI › YAML › дефолт**. Кода-дефолта стратегии нет —
имя всегда приходит либо из флага, либо из конфига.

Для быстрой проверки правила без изменения YAML используйте повторяемый `--set`:

```bash
bundle exec bin/route reference/data/operations_queue_10.json \
  --set providers.vipay.traffic_percentage=15
```

Значение действует только в текущем процессе. Опечатка в обычном пути печатает
warning в stderr; поля провайдера разрешены только из явного списка, а имя
провайдера проверяется по загруженному снапшоту.

<details>
<summary><b>Готовые конфигурации</b></summary>

<br>

| Файл | Что показывает |
|---|---|
| `config/examples/adwords.yml` | слои включены: BALANCE-подход к дневному бюджету |
| `config/examples/selector_full.yml` | все четыре предиката селектора стратегий |
| `config/examples/scripted_cascade.yml` | каскад с отказом, исходы заданы сценарием |
| `config/examples/tz_literal.yml` | буквальная трактовка ТЗ по fallback |
| `config/examples/tuning/` | шесть комбинаций для сравнения, с замерами |

</details>

---

## Демо

### Одна строка YAML меняет распределение

```bash
sed 's/^strategy: count_share$/strategy: round_robin/' config/routing.yml > /tmp/rr.yml
bundle exec bin/route reference/data/operations_queue_10.json --config /tmp/rr.yml
```

| Строка в конфиге | payflow | quickpay | vipay | spacepayments |
|---|:---:|:---:|:---:|:---:|
| `strategy: count_share` | 3 | 3 | 4 | 0 |
| `strategy: round_robin` | 4 | 3 | 3 | 0 |

Валидатор на обоих прогонах зелёный. Проверяется автоматически —
`spec/bin/config_switch_spec.rb`.

Разница выглядит скромно, потому что публичная очередь тесная: половину заявок
берёт единственный подходящий провайдер, и выбирать там не из чего. Стратегия
видна не в счёте, а в отклонении от **достижимой** доли по объёму — `count_share`
попадает в неё точно (0.0 п.п. у всех), `round_robin` промахивается на 3.9 п.п.
(см. `docs/ARCHITECTURE.md` §8).

Подменять так можно не любую стратегию: блок `comparison` в боевом конфиге
требует, чтобы среди его вариантов был ровно текущий `strategy` + `layers`,
иначе запуск честно падает на валидации схемы. Стратегии вне этого списка
пробуйте флагом `--strategy` либо добавляйте вариант в `comparison`.

### Каскад с отказом

```bash
bundle exec bin/route reference/data/operations_queue_10.json \
  --config config/examples/scripted_cascade.yml
```

`op_101` уходит в `payflow` после отказа `vipay` — в `attempts` две реальные
попытки и причина `next_in_cascade`. Исход задан сценарием, поэтому результат
не зависит от `--seed`.

Отдельный конфиг здесь нужен потому, что боевой сдаёт `outcomes.source:
always_ok` — на тестовой очереди все операции должны быть `approved` по
указанию организаторов (`docs/RUNBOOK.md` §2), и отказов в сдаваемом файле нет
по построению. Каскад от этого никуда не делся: он показывается этой командой,
прогоном `--outcomes deterministic --seed 42` и спеками `spec/execution/`.

### Новая стратегия без правок ядра

```bash
scripts/demo_new_strategy.sh
```

Кладёт файл в `lib/routing/strategies/`, добавляет строку в конфиг, прогоняет и
убирает за собой. Ни `bin/route`, ни реестр о новой стратегии не знают.

---

## Нагрузочная проверка

Генератор строит заявки, для которых правильный ответ известен заранее по
построению, и проверяет движок против него.

```bash
make bench LEVEL=m     # 100 000 заявок, 20 провайдеров
make bench LEVEL=l     # 1 000 000 заявок, 50 провайдеров
```

| Уровень | Заявок | Провайдеров | Память | Контрольных якорей | Нарушений |
|---|---:|---:|---:|---:|---:|
| `m` | 100 000 | 20 | 172 МБ | 4432 | 0 |
| `l` | 1 000 000 | 50 | 292 МБ | 8065 | 0 |

Память растёт в 1.7 раза при росте объёма в 10 раз — очередь читается потоково.

<details>
<summary><b>Сравнение конфигураций между собой</b></summary>

<br>

```bash
make bench-configs                     # все стратегии
make bench-configs LEVEL=compare_m     # на 100 000 заявок
```

Стратегии, знающие про целевые доли, держат максимальную долю провайдера около
10%; остальные сваливают до 90% трафика одному — они оптимизируют свою цель, а
не распределение.

</details>

---

## Алгоритмы

| Алгоритм | Источник | Где в коде |
|---|---|---|
| Метод Сент-Лагю | Balinski, Young. *Fair Representation*, Brookings, 2001 | `strategies/count_share.rb` |
| Deficit Round Robin | Shreedhar, Varghese. *Efficient Fair Queueing Using DRR*, IEEE/ACM ToN 4(3), 1996 | `strategies/volume_share.rb` |
| AdWords / BALANCE | Mehta, Saberi, Vazirani, Vazirani. *AdWords and Generalized Online Matching*, FOCS 2005 | `layers/budget_headroom.rb` |
| Лексикографическое goal programming | Charnes, Cooper. *Management Models and Industrial Applications of Linear Programming*, Wiley, 1961 | `layer_stack.rb` |

---

## HTTP-сервис (preview)

Минимальный HTTP-слой поверх того же ядра: потоковая обработка, общее in-memory
состояние провайдеров, аналитика из SQLite. CLI остаётся главной точкой входа.

Контракт — `docs/openapi.yaml` (OpenAPI 3.0.3, 12 путей, 23 схемы). Посмотреть
без запуска сервера:

```bash
xdg-open public/swagger/index.html
```

Ядро (`lib/routing`, `lib/execution`, `lib/state`) в HTTP-слое не меняется ни на
строку.

---

## Чего здесь нет

Нейросетей и ML · очередей и брокеров · DSL правил · единого композитного
скоринга · look-ahead-оптимизации по всей очереди

**В ядре нет базы данных.** Движок читает файлы и пишет файлы, состояние живёт
в памяти процесса. SQLite появляется только в HTTP-слое (см. выше) — там она
хранит историю решений для демонстрационного API и на роутинг не влияет.

Look-ahead исключён требованием онлайн-обработки: каждая заявка получает свой
снимок состояния. Композитный скоринг — требованием объяснимости: число,
собранное из десяти слагаемых с весами, не объясняет ни одного решения.

---

## Документация

Устройство движка, контракты модулей, форматы файлов и инварианты —
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

Команды запуска, все CLI-флаги, ключи YAML и готовые конфигурации —
[`docs/CONFIGURATION.md`](docs/CONFIGURATION.md).

Контракт HTTP-слоя — [`docs/openapi.yaml`](docs/openapi.yaml).
