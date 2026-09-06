# Запуск и конфигурация

Это практическая инструкция для запуска, демонстрации и изменения поведения
роутера. Описание внутренних контрактов и алгоритмов находится в
[`ARCHITECTURE.md`](ARCHITECTURE.md); регламент сдачи — в
[`RUNBOOK.md`](RUNBOOK.md).

## Быстрый старт

Из корня репозитория:

```bash
bundle exec bin/route reference/data/operations_queue_10.json
make validate
```

По умолчанию результат записывается в `out/`:

| Файл | Содержимое |
|---|---|
| `routing_decisions_test.json` | решение и все рассмотренные кандидаты по каждой операции |
| `routing_report_test.json` | распределение, причины отклонений, лимиты, экономика и рекомендации |

Для другого каталога используйте `--out-dir DIR`. `make deliver` записывает
оба файла в корень репозитория — это команда для подготовки сдачи.

## Входы и флаги

```text
bundle exec bin/route QUEUE.json [options]
```

| Флаг | Назначение |
|---|---|
| `--providers PATH` | иной JSON-снапшот провайдеров |
| `--history PATH` | иной CSV истории для калибровки и отчёта |
| `--config PATH` | иной YAML-конфиг вместо `config/routing.yml` |
| `--out-dir DIR` | каталог результатов |
| `--strategy NAME` | активная стратегия: `count_share`, `volume_share`, `priority`, `amount_range`, `conversion`, `load`, `obligations`, `round_robin` |
| `--outcomes NAME` | источник исходов: `always_ok`, `deterministic`, `scripted`, `always_fail` |
| `--seed SEED` | seed источника `deterministic` |
| `--script PATH` | YAML-сценарий для `--outcomes scripted` |
| `--set KEY=VALUE` | временно заменить настройку; флаг можно повторять |
| `--offline-analytics` | принудительно включить оракул и comparison на большой очереди |
| `--no-offline-analytics` | принудительно их отключить |

Порядок обычных источников: CLI-флаг → YAML → дефолт. `--set` применяется к
YAML до валидации и предназначен для коротких экспериментов: не меняет файл и
действует только в текущем процессе. Неизвестный путь печатает warning в
stderr, а не создаёт неработающий ключ.

Примеры:

```bash
# Сравнить распределение при другой целевой доле, не меняя YAML.
bundle exec bin/route reference/data/operations_queue_10.json \
  --set providers.vipay.traffic_percentage=15 --out-dir /tmp/vipay-15

# Прогнать текущий конфиг с другой стратегией и детерминированными исходами.
bundle exec bin/route reference/data/operations_queue_10.json \
  --strategy volume_share --outcomes deterministic --seed 42
```

Для провайдера `--set` разрешает только: `traffic_percentage`,
`volume_share_pct`, `daily_amount_limit`, `conversion_24h`, `priority`.
Имя проверяется по реально загруженному снапшоту.

## Устройство YAML

Минимальный рабочий YAML содержит `strategy` и `fallback_provider`. Остальные
поля необязательны и имеют безопасные дефолты. Начинайте с
`config/routing.annotated.yml`: это прокомментированная побайтово эквивалентная
копия боевого конфига.

| Ключ | Тип и пример | Что меняет |
|---|---|---|
| `history_path` | путь CSV | историю для conversion, исходов и отчёта |
| `providers_extra_path` | путь YAML | overlay четырёх дополнительных полей поверх любого снапшота |
| `strategy` | строка | основной порядок допустимых кандидатов |
| `layers` | список строк | лексикографические модификаторы порядка |
| `goals` | map | пороги включённых слоёв |
| `strategy_selection` | map | условный выбор стратегии на операции |
| `outcomes` | map | моделирование результатов попыток |
| `amount_ranges` | список диапазонов | предпочтение в стратегии `amount_range` |
| `obligations` | map провайдеров | дневние min/max оборота для `obligations` |
| `rate_limits` | map провайдеров → integer | максимум попыток в минуту |
| `cascade` | map | поведение после исчерпания и таймаута |
| `fallback_provider` | строка | self-provider, когда обычных кандидатов нет |
| `pending_resolution` | map | второй проход по зависшим выплатам |
| `offline_analytics` | map | лимит очереди для дорогой аналитики |
| `comparison` | список вариантов | офлайновое сравнение стратегий в отчёте |

Неизвестный верхнеуровневый ключ и неверный тип — ошибка загрузки. Это
намеренно: конфигурация с опечаткой не должна выглядеть применённой.

### Стратегия, слои и цели

```yaml
strategy: count_share
layers: [budget_headroom, share_ceiling]
goals:
  budget_headroom: { activates_at_spent_pct: 90 }
  share_ceiling: { tolerance_bp: 0 }
```

`layers` применяются в указанном порядке: первый имеет высший приоритет.
Доступны `budget_headroom` и `share_ceiling`; сами настройки в `goals` без
добавления слоя ничего не меняют. Пример —
[`config/examples/adwords.yml`](../config/examples/adwords.yml).

`amount_ranges` — не ограничение допуска, а предпочтение стратегии:

```yaml
amount_ranges:
  - { from: 500, to: 50000, prefer: payflow }
  - { from: 50001, to: 100000, prefer: vipay }
  - { from: 100001, to: null, prefer: quickpay }
```

### Условный селектор стратегий

Вместо одной стратегии можно выбирать её по данным операции. Правила идут
сверху вниз; в одном `when` условия объединены через И.

```yaml
strategy_selection:
  default: count_share
  rules:
    - when: { amount_gte: 100000, bank_in: [sberbank] }
      use: conversion
      why: "крупная сумма — приоритет проходимости"
```

Предикаты: `amount_gte`, `amount_lt`, `bank_in`, `eligible_count_lte`.
Полный пример, в котором срабатывает каждый из них —
[`config/examples/selector_full.yml`](../config/examples/selector_full.yml).

### Исходы и каскад

```yaml
outcomes:
  source: deterministic
  seed: 42
  calibrate_from_history: true
  smoothing: true
cascade:
  exhausted: last_candidate   # или fallback_provider
  on_timeout: stop            # или continue
```

`always_ok` — боевой режим для очереди организаторов. `deterministic` вычисляет
воспроизводимый исход по seed и калиброванной истории. `scripted` берёт исход
каждой пары «операция—провайдер» из `outcomes.script` или файла `--script`.
Для наглядной демонстрации отказа и перехода к следующему кандидату используйте
[`config/examples/scripted_cascade.yml`](../config/examples/scripted_cascade.yml).

Таймаут не является обычным отказом: при `on_timeout: stop` каскад
останавливается, а резерв остаётся до второго прохода. `pending_resolution:
{ enabled: false }` полностью отключает этот проход и секцию отчёта.

### Лимиты, обязательства и comparison

```yaml
obligations:
  payflow: { daily_turnover_min: 2000000 }
  vipay: { daily_turnover_max: 5000000 }
rate_limits:
  vipay: 7
comparison:
  - { name: baseline, strategy: count_share, layers: [] }
  - { name: fair_volume, strategy: volume_share, layers: [] }
```

`obligations` накладывается поверх снимка. `rate_limits` допускает только
целые значения. В `comparison` ровно один вариант обязан совпадать с боевыми
`strategy` и `layers`: это baseline, с которым сравнивается реальный прогон.

## Файлы провайдеров и истории

По умолчанию используется `data/providers.json` — расширенный снапшот проекта.
`reference/data/providers.json` является снапшотом организаторов; передавайте
его явно через `--providers`, когда нужно проверить совместимость с их входом.
`null` в лимите означает отсутствие ограничения, не ноль.

История — CSV, указанный в `history_path` или `--history`. Она читается ровно
один раз и используется для модели `deterministic`, стратегии `conversion` и
секций `conversion_check`/`outcomes_summary` отчёта.

Если организаторы выдали свой `providers.json`, дополнительные поля проекта
не нужно вписывать в их файл. Создайте отдельный YAML и укажите его в конфиге:

```yaml
providers_extra_path: config/providers_extra.yml
```

```yaml
# config/providers_extra.yml
providers:
  vipay:
    volume_share_pct: 40
    requests_per_minute_limit: 7
  payflow:
    daily_turnover_min: 2000000
```

Разрешены только `volume_share_pct`, `requests_per_minute_limit`,
`daily_turnover_min`, `daily_turnover_max`; неизвестный провайдер — ошибка.

## Готовые режимы

| Цель | Команда |
|---|---|
| Боевая сдача | `make deliver` |
| Проверка формата организаторов | `make validate` |
| Два идентичных прогона | `make determinism` |
| Демонстрация каскада | `bundle exec bin/route reference/data/operations_queue_10.json --config config/examples/scripted_cascade.yml` |
| Слои BALANCE | `bundle exec bin/route reference/data/operations_queue_10.json --config config/examples/adwords.yml` |
| Полный селектор | `bundle exec bin/route reference/data/operations_queue_10.json --config config/examples/selector_full.yml` |
