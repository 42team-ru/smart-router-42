# Routing Console

Пульт движка: чистые HTML/CSS/JS, без сборки и без зависимостей. Своих данных
не держит — всё на экране приходит из HTTP-API и пересобирается при каждой
перезагрузке.

```
dashboard/
├── index.html              разметка четырёх экранов
└── assets/
    ├── css/console.css     токены темы + вёрстка
    └── js/
        ├── format.js       форматтеры чисел/времени и цвета исходов
        ├── api.js          HTTP-клиент, единственное место, знающее про сеть
        └── app.js          состояние интерфейса и отрисовка
```

## Как открыть

```sh
bin/serve                     # http://localhost:4567/console/
```

Раздаёт `Api::App` (маршруты `/console`, `/console/`, `/console/*`), каталог —
`service.dashboard_path` в `config/service.yml`. Против чужого сервиса:
`/console/?api=http://хост:порт`.

Сервису нужен снапшот: без него `/state`, `/report` и `/analytics/*` отвечают
409 `no_snapshot`, и консоль показывает заглушку с готовой командой загрузки.

```sh
ruby -rjson -ryaml -e '
  snapshot = JSON.parse(File.read("reference/data/providers.json"))
  config   = YAML.safe_load_file("config/routing.yml")
  print JSON.generate("snapshot" => snapshot, "config" => config)' \
| curl -sS -X POST -H 'Content-Type: application/json' --data-binary @- \
       http://localhost:4567/bootstrap
```

## Откуда что берётся

| Экран | Ручки |
| --- | --- |
| Обзор | `/analytics/overview` (исходы, каскад, ряды по времени), `/state` + `/snapshot` (доли, лимиты, реквизиты), `/report` (наблюдаемая конверсия, `skip_reasons`, рекомендации) |
| Симулятор | `POST /operations`, `POST /operations/batch` |
| Аналитика | те же пять фильтров в `/analytics/overview`, `/report` и `/analytics/decisions` |
| Контекст | `/config`, `/capabilities`, `/snapshot`, `/health`; кнопки шлют `POST /config`, `/bootstrap`, `/reset` |

Фильтры уходят на сервер как query-параметры и применяются как WHERE до
агрегации — клиент ничего не досчитывает и не досортировывает. Единственное,
что считается в браузере, — раскладка чисел по пикселям графиков.

Формы дозаполняют `operation_id` и `created_at`, если их не задали руками:
это удобство ввода, а не подстановка данных — сами суммы, банки и реквизиты
уходят как есть.

Тема (светлая/тёмная) переключается в шапке и запоминается в `localStorage`.
Больше в браузере не хранится ничего.
