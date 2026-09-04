# Промпт W2 — слой `budget_headroom` (ψ из AdWords), задача X-2

Запускать после W1. Это первый настоящий слой в проекте.

```
Проект smart-routing-42, /home/vmelnik/RubymineProjects/smart-routing-42.
Фаза Ф4, задача X-2. Делаешь пакет W2. W3, W4, W5 не трогай.

## Бриф

docs/plans/PHASE_4_VOVA.md, «БРИФ W2» (строки 668–780). Прочитай также §3.4
(как ψ сочетается со стратегией), §3.5 (как считается ψ без float), §3.7
(что пишется в attempts) и §8 (что может сломаться молча).

## Что делаешь

lib/routing/layers/budget_headroom.rb — слой BALANCE из задачи AdWords:
psi(T) = 1 - e^(T-1), где T = daily_approved_amount / daily_amount_limit.
Провайдер с почти исчерпанным бюджетом сам опускается в хвост каскада,
headroom сохраняется для операций, которым больше некуда идти.

## Числа приёмки — критерий задачи X-2 из docs/TASKS.md, дословный

На reference/data/providers.json psi_micro обязан дать:

  quickpay  577_895   ->  текст 0.578
  vipay     302_324   ->  текст 0.302
  payflow    32_784   ->  текст 0.033

Отклонение при пороге 100_000: payflow 67_216, vipay 0, quickpay 0.
Проверены точной рациональной арифметикой при планировании. Если твой прогон
даёт другое — остановись и скажи.

## Главное ограничение

psi вещественная, а у нас инвариант целочисленной арифметики. Способ
зафиксирован планом и обсуждению не подлежит: Rational + ряд Тейлора,
16 членов (константа TAYLOR_TERMS, не параметр), результат — целое в
микро-единицах 0..1_000_000. Ни Float, ни to_f, ни Math.exp, ни таблиц.
Ошибка усечения < 5e-14 против единицы округления 1e-6.

Форматирование текста тоже целочисленное:
  format('0.%03d', (psi_micro + 500) / 1000)

## Живое состояние, а не снапшот

live_daily_approved: если state отвечает на daily_approved_amount — берём
state.daily_approved_amount(provider.name), иначе provider.daily_approved_amount.to_i
(второй путь нужен юнит-спекам, которые передают ShareLedger). Спек №5 из брифа
обязан использовать State::Providers и показать, что psi после commit падает:
32_784 -> 16_529 при операции на 50_000.

## Граничные случаи

daily_amount_limit nil (spacepayments) -> psi = 1_000_000, отклонение 0, без падения.
limit == 0 -> трактуем как «бюджета нет», psi = 1.0, не деление на ноль.
daily_approved > limit (перерасход возможен уже сегодня) -> psi = 0, не исключение.

## Конфиг

Новый пример config/examples/adwords.yml — копия боевого с
layers: [budget_headroom]. Боевой config/routing.yml НЕ ТРОГАЙ.

## Сквозная проверка

  bundle exec bin/route reference/data/operations_queue_10.json \
    --config config/examples/adwords.yml --out-dir /tmp/psi
  ruby reference/scripts/validate_10.rb /tmp/psi/routing_decisions_test.json

Обязано дать «Ошибок: 0». В decisions для op_101, op_102 и op_110 payflow либо
отсутствует среди selected-попыток, либо имеет наибольший attempt_no среди них.
op_107 остаётся за payflow — он там единственный допустимый.

## Дополнительно

Спек №8 из брифа (класс не содержит Float) предпочтительно вносить не спеком, а
правилом в scripts/check_determinism.sh — тогда оно защищает весь каталог слоёв,
а не один файл.
```

Дальше — общая часть из `00_ОБЩИЙ_КОНТЕКСТ.md` (инварианты, готовность, отчёт).
