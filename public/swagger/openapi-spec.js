window.OPENAPI_SPEC = {
  "openapi": "3.0.3",
  "info": {
    "title": "smart-router-42 HTTP API",
    "version": "0.1.0",
    "description": "HTTP-обвязка поверх CLI-ядра `bin/route`. Потоковая обработка одной операции\nза запрос, глобальное in-memory состояние `State::Providers`, аналитика в\nSQLite с настраиваемым retention. CLI остаётся основной точкой входа для\nвалидатора организаторов; сервис — параллельный демонстрационный слой.\n\n**Инварианты домена (см. CLAUDE.md, ARCHITECTURE.md §1-§6):**\n- Детерминизм: тот же вход + тот же порядок = байт-в-байт тот же выход.\n- Онлайн-обработка: look-ahead запрещён, каждая операция получает снапшот на\n  момент прихода.\n- Причина отсева без числа не принимается (`details` содержит конкретное\n  сравнение).\n- `selected_provider` обязан входить в множество допустимых по исходному\n  снапшоту (spacepayments — fallback по допуску).\n\n**Модель конкурентности:** Puma workers=1, threads=1. Все запросы\nсериализуются сервером, локи внутри приложения не используются.\n\n**Reset-семантика:** `POST /snapshot`, `POST /config`, `POST /bootstrap`,\n`POST /reset` — все destructive: очищают in-memory состояние и таблицу\nрешений в SQLite. Смена контекста = сброс аналитики.\n",
    "contact": {
      "name": "smart-router-42",
      "url": "https://github.com/mkass420/smart-router-42"
    }
  },
  "servers": [
    {
      "url": "http://localhost:4567",
      "description": "Локальный dev-сервер (Puma, bin/serve)"
    }
  ],
  "tags": [
    {
      "name": "Context",
      "description": "Управление снапшотом провайдеров, конфигом и сбросом состояния. Все эндпоинты destructive."
    },
    {
      "name": "Routing",
      "description": "Обработка операций — одна за раз или batch-сахар."
    },
    {
      "name": "Analytics",
      "description": "Живой отчёт (routing_report) и постраничная выгрузка сырых решений."
    },
    {
      "name": "Infrastructure",
      "description": "Health-check, OpenAPI-спека, Swagger UI."
    }
  ],
  "paths": {
    "/snapshot": {
      "post": {
        "tags": [
          "Context"
        ],
        "summary": "Загрузить снапшот провайдеров",
        "description": "Полная перезагрузка провайдеров (обычно начало «дня» или демо).\n**Destructive:** очищает in-memory state и таблицу decisions.\nКонфиг сохраняется из последней загрузки (или из `config/routing.yml`,\nесли конфиг ещё не грузили).\n",
        "operationId": "loadSnapshot",
        "requestBody": {
          "required": true,
          "content": {
            "application/json": {
              "schema": {
                "$ref": "#/components/schemas/SnapshotRequest"
              },
              "examples": {
                "default": {
                  "$ref": "#/components/examples/SnapshotRequestExample"
                }
              }
            }
          }
        },
        "responses": {
          "200": {
            "description": "Снапшот загружен",
            "content": {
              "application/json": {
                "schema": {
                  "$ref": "#/components/schemas/ContextOkResponse"
                },
                "example": {
                  "status": "ok",
                  "providers_count": 4,
                  "gateway": "RUB_SBP_WITHDRAW",
                  "merchant": "alpha_market",
                  "strategy": "count_share"
                }
              }
            }
          },
          "400": {
            "$ref": "#/components/responses/ValidationFailed"
          }
        }
      }
    },
    "/config": {
      "post": {
        "tags": [
          "Context"
        ],
        "summary": "Применить новый конфиг",
        "description": "Заменяет текущий конфиг роутинга (стратегия, слои, seed, thresholds).\n**Destructive:** очищает in-memory state и таблицу decisions (агрегаты\nпо разным правилам не имеют смысла).\nТребует предварительно загруженного снапшота.\n",
        "operationId": "applyConfig",
        "requestBody": {
          "required": true,
          "content": {
            "application/json": {
              "schema": {
                "$ref": "#/components/schemas/ConfigRequest"
              },
              "examples": {
                "default": {
                  "$ref": "#/components/examples/ConfigRequestExample"
                }
              }
            }
          }
        },
        "responses": {
          "200": {
            "description": "Конфиг применён",
            "content": {
              "application/json": {
                "schema": {
                  "$ref": "#/components/schemas/ContextOkResponse"
                },
                "example": {
                  "status": "ok",
                  "providers_count": 4,
                  "gateway": "RUB_SBP_WITHDRAW",
                  "merchant": "alpha_market",
                  "strategy": "volume_share"
                }
              }
            }
          },
          "400": {
            "$ref": "#/components/responses/ValidationFailed"
          },
          "409": {
            "$ref": "#/components/responses/NoSnapshot"
          }
        }
      }
    },
    "/bootstrap": {
      "post": {
        "tags": [
          "Context"
        ],
        "summary": "Загрузить снапшот и конфиг одним запросом (сахар)",
        "description": "Комбинирует `POST /snapshot` и `POST /config`. Оба поля обязательны.\n**Destructive:** очищает in-memory state и таблицу decisions.\nУдобно для инициализации сервиса с нуля одним curl-запросом.\n",
        "operationId": "bootstrap",
        "requestBody": {
          "required": true,
          "content": {
            "application/json": {
              "schema": {
                "$ref": "#/components/schemas/BootstrapRequest"
              },
              "examples": {
                "default": {
                  "$ref": "#/components/examples/BootstrapRequestExample"
                }
              }
            }
          }
        },
        "responses": {
          "200": {
            "description": "Готово",
            "content": {
              "application/json": {
                "schema": {
                  "$ref": "#/components/schemas/ContextOkResponse"
                },
                "example": {
                  "status": "ok",
                  "providers_count": 4,
                  "gateway": "RUB_SBP_WITHDRAW",
                  "merchant": "alpha_market",
                  "strategy": "count_share"
                }
              }
            }
          },
          "400": {
            "$ref": "#/components/responses/ValidationFailed"
          }
        }
      }
    },
    "/reset": {
      "post": {
        "tags": [
          "Context"
        ],
        "summary": "Сбросить состояние и аналитику, сохранив снапшот и конфиг",
        "description": "Восстанавливает `State::Providers` из последнего загруженного\nснапшота и очищает таблицу `decisions`. Конфиг и snapshot остаются\nв силе. Возвращает 409, если ни snapshot, ни bootstrap не вызывались.\n",
        "operationId": "reset",
        "responses": {
          "200": {
            "description": "Сброшено",
            "content": {
              "application/json": {
                "schema": {
                  "type": "object",
                  "required": [
                    "status"
                  ],
                  "properties": {
                    "status": {
                      "type": "string",
                      "enum": [
                        "ok"
                      ]
                    }
                  }
                },
                "example": {
                  "status": "ok"
                }
              }
            }
          },
          "409": {
            "$ref": "#/components/responses/NoSnapshot"
          }
        }
      }
    },
    "/operations": {
      "post": {
        "tags": [
          "Routing"
        ],
        "summary": "Обработать одну операцию",
        "description": "Прогоняет операцию через `Routing::Planner` + `Execution::Executor` на\nтекущем in-memory `State::Providers`. Мутирует состояние (резервирует\ncapacity, коммитит/откатывает по исходу), записывает решение в SQLite.\nВозвращает decision в формате `routing_decisions_test.json[i]`.\n",
        "operationId": "routeOperation",
        "requestBody": {
          "required": true,
          "content": {
            "application/json": {
              "schema": {
                "$ref": "#/components/schemas/OperationRequest"
              },
              "examples": {
                "default": {
                  "$ref": "#/components/examples/OperationRequestExample"
                }
              }
            }
          }
        },
        "responses": {
          "200": {
            "description": "Решение принято (в том числе если simulated_result = rejected/expired)",
            "content": {
              "application/json": {
                "schema": {
                  "$ref": "#/components/schemas/Decision"
                },
                "example": {
                  "operation_id": "op_106",
                  "selected_provider": "vipay",
                  "attempts": [
                    {
                      "provider": "payflow",
                      "decision": "skipped",
                      "reason": "amount_exceeds_limit",
                      "details": "52000 > limit_amount_max 50000"
                    },
                    {
                      "provider": "vipay",
                      "decision": "selected",
                      "reason": "best_target_adherence",
                      "details": "count_share: vipay 4000/5=800 против quickpay 2500/5=500",
                      "strategy": "count_share",
                      "attempt_no": 1,
                      "result": "approved"
                    }
                  ],
                  "simulated_result": "approved",
                  "latency_sec": 38
                }
              }
            }
          },
          "400": {
            "$ref": "#/components/responses/ValidationFailed"
          },
          "409": {
            "$ref": "#/components/responses/NoSnapshot"
          }
        }
      }
    },
    "/operations/batch": {
      "post": {
        "tags": [
          "Routing"
        ],
        "summary": "Обработать пачку операций (сахар)",
        "description": "Принимает массив операций, **внутри обрабатывает по одной строго\nпоследовательно** — семантика та же, что при цикле `POST /operations`.\nНе транзакционно: каждая операция уже применённая, останется в state и\nБД, даже если следующая упадёт валидацией.\nПолезно для демо и для сравнения выхода с CLI на всей очереди одним\nзапросом.\n",
        "operationId": "routeBatch",
        "requestBody": {
          "required": true,
          "content": {
            "application/json": {
              "schema": {
                "$ref": "#/components/schemas/OperationsBatchRequest"
              },
              "examples": {
                "default": {
                  "$ref": "#/components/examples/OperationsBatchRequestExample"
                }
              }
            }
          }
        },
        "responses": {
          "200": {
            "description": "Все операции обработаны",
            "content": {
              "application/json": {
                "schema": {
                  "type": "object",
                  "required": [
                    "decisions"
                  ],
                  "properties": {
                    "decisions": {
                      "type": "array",
                      "items": {
                        "$ref": "#/components/schemas/Decision"
                      }
                    },
                    "processed": {
                      "type": "integer",
                      "description": "Сколько операций фактически прошли (= длине decisions)"
                    }
                  }
                }
              }
            }
          },
          "400": {
            "description": "Валидация упала на первой битой операции; предыдущие уже применены и не откатываются",
            "content": {
              "application/json": {
                "schema": {
                  "allOf": [
                    {
                      "$ref": "#/components/schemas/Error"
                    },
                    {
                      "type": "object",
                      "properties": {
                        "details": {
                          "type": "object",
                          "properties": {
                            "failed_index": {
                              "type": "integer",
                              "description": "Индекс операции в массиве, на которой упала валидация"
                            },
                            "processed": {
                              "type": "integer",
                              "description": "Сколько операций до неё уже применены (необратимо)"
                            }
                          }
                        }
                      }
                    }
                  ]
                }
              }
            }
          },
          "409": {
            "$ref": "#/components/responses/NoSnapshot"
          }
        }
      }
    },
    "/report": {
      "get": {
        "tags": [
          "Analytics"
        ],
        "summary": "Агрегированный отчёт по прошедшим решениям",
        "description": "Собирает `routing_report_test.json`-совместимую структуру из таблицы\n`decisions` через SQL-запросы. Все фильтры применяются как WHERE-условия\nдо агрегации. Отсутствие фильтра = без ограничения.\nHeader `period`, `total_operations`, `strategy` отражают фактическую\nвыборку (после фильтров) и текущий загруженный конфиг.\n",
        "operationId": "getReport",
        "parameters": [
          {
            "$ref": "#/components/parameters/SinceParam"
          },
          {
            "$ref": "#/components/parameters/UntilParam"
          },
          {
            "$ref": "#/components/parameters/MerchantParam"
          },
          {
            "$ref": "#/components/parameters/GateParam"
          },
          {
            "$ref": "#/components/parameters/ProviderParam"
          }
        ],
        "responses": {
          "200": {
            "description": "Отчёт построен",
            "content": {
              "application/json": {
                "schema": {
                  "$ref": "#/components/schemas/Report"
                }
              }
            }
          }
        }
      }
    },
    "/decisions": {
      "get": {
        "tags": [
          "Analytics"
        ],
        "summary": "Постраничная выгрузка сырых решений",
        "description": "Возвращает элементы в формате `routing_decisions_test.json[i]`.\nСортировка — по `id ASC` (порядок обработки). Retention SQLite может\nобрезать хвост старше `retention_hours` (см. `/health`).\n",
        "operationId": "listDecisions",
        "parameters": [
          {
            "$ref": "#/components/parameters/SinceParam"
          },
          {
            "$ref": "#/components/parameters/UntilParam"
          },
          {
            "$ref": "#/components/parameters/MerchantParam"
          },
          {
            "$ref": "#/components/parameters/GateParam"
          },
          {
            "$ref": "#/components/parameters/ProviderParam"
          },
          {
            "name": "limit",
            "in": "query",
            "description": "Максимум элементов в ответе (1..500, дефолт 100)",
            "schema": {
              "type": "integer",
              "minimum": 1,
              "maximum": 500,
              "default": 100
            }
          },
          {
            "name": "offset",
            "in": "query",
            "description": "Смещение с начала выборки",
            "schema": {
              "type": "integer",
              "minimum": 0,
              "default": 0
            }
          }
        ],
        "responses": {
          "200": {
            "description": "Список решений",
            "content": {
              "application/json": {
                "schema": {
                  "$ref": "#/components/schemas/DecisionsListResponse"
                }
              }
            }
          }
        }
      }
    },
    "/state": {
      "get": {
        "tags": [
          "Analytics"
        ],
        "summary": "Снимок текущего in-memory состояния провайдеров",
        "description": "Отдаёт счётчики `State::Providers` на момент запроса: `in_progress_*`,\n`daily_approved_amount`, `available_requisites`, а также текущую долю\nпо стратегии в базисных пунктах.\n",
        "operationId": "getState",
        "responses": {
          "200": {
            "description": "Состояние",
            "content": {
              "application/json": {
                "schema": {
                  "$ref": "#/components/schemas/State"
                }
              }
            }
          },
          "409": {
            "$ref": "#/components/responses/NoSnapshot"
          }
        }
      }
    },
    "/health": {
      "get": {
        "tags": [
          "Infrastructure"
        ],
        "summary": "Health-check",
        "operationId": "getHealth",
        "responses": {
          "200": {
            "description": "Сервис жив",
            "content": {
              "application/json": {
                "schema": {
                  "$ref": "#/components/schemas/Health"
                },
                "example": {
                  "status": "ok",
                  "snapshot_loaded": true,
                  "decisions_count": 42,
                  "retention_hours": 24,
                  "strategy": "count_share",
                  "version": "0.1.0"
                }
              }
            }
          }
        }
      }
    },
    "/openapi.yaml": {
      "get": {
        "tags": [
          "Infrastructure"
        ],
        "summary": "Отдать эту спеку (файл docs/openapi.yaml)",
        "operationId": "getOpenApiSpec",
        "responses": {
          "200": {
            "description": "OpenAPI-спека",
            "content": {
              "application/yaml": {
                "schema": {
                  "type": "string"
                }
              }
            }
          }
        }
      }
    },
    "/swagger": {
      "get": {
        "tags": [
          "Infrastructure"
        ],
        "summary": "Swagger UI",
        "description": "HTML-страница Swagger UI, читает `/openapi.yaml`. Раздаётся статикой из `public/swagger/`.",
        "operationId": "getSwaggerUi",
        "responses": {
          "200": {
            "description": "HTML",
            "content": {
              "text/html": {
                "schema": {
                  "type": "string"
                }
              }
            }
          }
        }
      }
    }
  },
  "components": {
    "parameters": {
      "SinceParam": {
        "name": "since",
        "in": "query",
        "description": "ISO 8601, включительно. Отсутствие = без нижней границы.",
        "schema": {
          "type": "string",
          "format": "date-time"
        },
        "example": "2026-07-30T09:00:00+03:00"
      },
      "UntilParam": {
        "name": "until",
        "in": "query",
        "description": "ISO 8601, исключительно. Отсутствие = без верхней границы.",
        "schema": {
          "type": "string",
          "format": "date-time"
        },
        "example": "2026-07-30T18:00:00+03:00"
      },
      "MerchantParam": {
        "name": "merchant",
        "in": "query",
        "description": "Фильтр по `merchant_id` (взятому из снапшота на момент решения).",
        "schema": {
          "type": "string"
        },
        "example": "alpha_market"
      },
      "GateParam": {
        "name": "gate",
        "in": "query",
        "description": "Фильтр по gateway (например, RUB_SBP_WITHDRAW).",
        "schema": {
          "type": "string"
        },
        "example": "RUB_SBP_WITHDRAW"
      },
      "ProviderParam": {
        "name": "provider",
        "in": "query",
        "description": "Фильтр по `selected_provider`.",
        "schema": {
          "type": "string"
        },
        "example": "vipay"
      }
    },
    "responses": {
      "ValidationFailed": {
        "description": "Тело запроса не прошло валидацию",
        "content": {
          "application/json": {
            "schema": {
              "$ref": "#/components/schemas/Error"
            },
            "example": {
              "error": "validation_failed",
              "message": "Operation payload invalid",
              "details": {
                "missing": [
                  "operation_id"
                ],
                "invalid": [
                  {
                    "field": "amount",
                    "code": "not_positive_integer",
                    "got": -100
                  }
                ]
              }
            }
          }
        }
      },
      "NoSnapshot": {
        "description": "Снапшот не загружен — вызовите `POST /snapshot` или `POST /bootstrap` первым",
        "content": {
          "application/json": {
            "schema": {
              "$ref": "#/components/schemas/Error"
            },
            "example": {
              "error": "no_snapshot",
              "message": "Call POST /snapshot or POST /bootstrap first"
            }
          }
        }
      }
    },
    "schemas": {
      "Provider": {
        "type": "object",
        "description": "Формат идентичен элементу `providers[]` в `reference/data/providers.json`.\nПоля с лимитами (`limit_amount_*`, `daily_amount_limit`,\n`in_progress_*_limit`) могут быть `null` для fallback-провайдера\n(`spacepayments`) — тогда лимит не применяется.\n",
        "required": [
          "payment_system",
          "status",
          "traffic_percentage",
          "priority",
          "daily_approved_amount",
          "in_progress_count",
          "in_progress_amount",
          "available_requisites",
          "conversion_24h",
          "avg_latency_sec",
          "banks",
          "exclude_banks",
          "provider_margin_pct",
          "merchant_margin_pct",
          "allow_negative_agreement"
        ],
        "properties": {
          "payment_system": {
            "type": "string",
            "example": "vipay"
          },
          "status": {
            "type": "string",
            "enum": [
              "active",
              "inactive"
            ],
            "example": "active"
          },
          "traffic_percentage": {
            "type": "integer",
            "minimum": 0,
            "maximum": 100,
            "example": 40
          },
          "priority": {
            "type": "integer",
            "minimum": 1,
            "example": 1
          },
          "limit_amount_min": {
            "type": "integer",
            "nullable": true,
            "example": 1000
          },
          "limit_amount_max": {
            "type": "integer",
            "nullable": true,
            "example": 100000
          },
          "daily_amount_limit": {
            "type": "integer",
            "nullable": true,
            "example": 5000000
          },
          "daily_approved_amount": {
            "type": "integer",
            "minimum": 0,
            "example": 3200000
          },
          "in_progress_count_limit": {
            "type": "integer",
            "nullable": true,
            "example": 10
          },
          "in_progress_count": {
            "type": "integer",
            "minimum": 0,
            "example": 4
          },
          "in_progress_amount_limit": {
            "type": "integer",
            "nullable": true,
            "example": 1000000
          },
          "in_progress_amount": {
            "type": "integer",
            "minimum": 0,
            "example": 380000
          },
          "available_requisites": {
            "type": "integer",
            "minimum": 0,
            "example": 12
          },
          "conversion_24h": {
            "type": "number",
            "minimum": 0,
            "maximum": 1,
            "example": 0.87
          },
          "avg_latency_sec": {
            "type": "integer",
            "minimum": 0,
            "example": 38
          },
          "banks": {
            "type": "array",
            "items": {
              "type": "string"
            },
            "example": [
              "sberbank",
              "tinkoff",
              "vtb"
            ]
          },
          "exclude_banks": {
            "type": "boolean",
            "description": "true = banks — чёрный список; false = белый",
            "example": false
          },
          "provider_margin_pct": {
            "type": "number",
            "example": 1.2
          },
          "merchant_margin_pct": {
            "type": "number",
            "example": 1.5
          },
          "allow_negative_agreement": {
            "type": "boolean",
            "example": false
          },
          "note": {
            "type": "string",
            "description": "Свободный комментарий (используется у spacepayments)"
          }
        }
      },
      "PayoutRequisite": {
        "type": "object",
        "description": "Реквизит выплаты. Сегодня поддерживается `sbp`. Схема оставлена\nсвободной (additionalProperties) под будущие каналы.\n",
        "additionalProperties": true,
        "properties": {
          "sbp": {
            "type": "object",
            "properties": {
              "phone": {
                "type": "string",
                "example": "79001234567"
              },
              "bank_name": {
                "type": "string",
                "example": "Сбербанк"
              }
            }
          }
        }
      },
      "Operation": {
        "type": "object",
        "description": "Формат идентичен элементу `operations_queue_test.json[i]`.",
        "required": [
          "operation_id",
          "created_at",
          "amount",
          "bank",
          "payout_requisite"
        ],
        "properties": {
          "operation_id": {
            "type": "string",
            "example": "op_106"
          },
          "created_at": {
            "type": "string",
            "format": "date-time",
            "example": "2026-07-30T09:07:30+03:00"
          },
          "amount": {
            "type": "integer",
            "minimum": 1,
            "example": 52000
          },
          "bank": {
            "type": "string",
            "example": "sberbank"
          },
          "card_brand": {
            "type": "string",
            "nullable": true,
            "example": null
          },
          "payout_requisite": {
            "$ref": "#/components/schemas/PayoutRequisite"
          }
        }
      },
      "Attempt": {
        "type": "object",
        "description": "Одна попытка каскада. `decision` принимает только `selected` или `skipped`\n(валидатор организаторов проверяет; неудачные попытки кодируются как\n`selected` + `result: rejected/expired`).\nПричины (`reason`) — дословно из `reference/data/reference_decisions.json`.\n`details` **обязан** содержать конкретное число («52000 > limit_amount_max 50000»).\n",
        "required": [
          "provider",
          "decision",
          "reason",
          "details"
        ],
        "properties": {
          "provider": {
            "type": "string",
            "example": "payflow"
          },
          "decision": {
            "type": "string",
            "enum": [
              "selected",
              "skipped"
            ],
            "example": "skipped"
          },
          "reason": {
            "type": "string",
            "description": "Skipped-причины: `amount_exceeds_limit`, `amount_below_minimum`,\n`bank_not_in_list`, `no_available_requisites`, `daily_amount_exhausted`,\n`in_progress_limit_reached`, `status_inactive` и т.п.\nSelected-причины: `best_target_adherence`, `only_eligible_provider`,\n`fallback_provider` и т.п.\n",
            "example": "amount_exceeds_limit"
          },
          "details": {
            "type": "string",
            "example": "52000 > limit_amount_max 50000"
          },
          "strategy": {
            "type": "string",
            "description": "Только для selected",
            "example": "count_share"
          },
          "attempt_no": {
            "type": "integer",
            "description": "Только для selected, порядковый номер (1-based)",
            "example": 1
          },
          "result": {
            "type": "string",
            "enum": [
              "approved",
              "rejected",
              "expired"
            ],
            "description": "Только для selected — исход попытки",
            "example": "approved"
          }
        }
      },
      "Decision": {
        "type": "object",
        "description": "Формат идентичен элементу `routing_decisions_test.json[i]`.",
        "required": [
          "operation_id",
          "selected_provider",
          "attempts",
          "simulated_result"
        ],
        "properties": {
          "operation_id": {
            "type": "string",
            "example": "op_106"
          },
          "selected_provider": {
            "type": "string",
            "nullable": true,
            "description": "null, если каскад исчерпан и fallback тоже отказал",
            "example": "vipay"
          },
          "attempts": {
            "type": "array",
            "items": {
              "$ref": "#/components/schemas/Attempt"
            }
          },
          "simulated_result": {
            "type": "string",
            "enum": [
              "approved",
              "rejected",
              "expired",
              "no_provider"
            ],
            "description": "Итог операции: `approved` — успех, `rejected` — все попытки отказали,\n`expired` — все попытки истекли по времени, `no_provider` — не нашлось\nдопустимого провайдера (даже fallback).\n",
            "example": "approved"
          },
          "latency_sec": {
            "type": "integer",
            "nullable": true,
            "description": "Латентность выбранного провайдера; null если no_provider",
            "example": 38
          }
        }
      },
      "Config": {
        "type": "object",
        "description": "Схема идентична `config/routing.yml` (после парсинга YAML в JSON).\nДополнительные ключи допустимы (`additionalProperties: true`) — конфиг\nрасширяется без ломки контракта.\n",
        "additionalProperties": true,
        "required": [
          "strategy",
          "outcomes",
          "fallback_provider"
        ],
        "properties": {
          "strategy": {
            "type": "string",
            "description": "Активная стратегия распределения.",
            "example": "count_share"
          },
          "layers": {
            "type": "array",
            "description": "Порядок слоёв поверх базовой стратегии (пусто = только базовая).",
            "items": {
              "type": "string"
            },
            "example": []
          },
          "goals": {
            "type": "object",
            "description": "Пороги для слоёв (инертны, если layers пуст).",
            "additionalProperties": true
          },
          "outcomes": {
            "type": "object",
            "required": [
              "source",
              "seed"
            ],
            "properties": {
              "source": {
                "type": "string",
                "enum": [
                  "deterministic"
                ],
                "example": "deterministic"
              },
              "seed": {
                "type": "integer",
                "example": 42
              },
              "calibrate_from_history": {
                "type": "boolean",
                "example": true
              }
            }
          },
          "amount_ranges": {
            "type": "array",
            "description": "Только для strategy=amount_range.",
            "items": {
              "type": "object",
              "required": [
                "from",
                "prefer"
              ],
              "properties": {
                "from": {
                  "type": "integer",
                  "example": 500
                },
                "to": {
                  "type": "integer",
                  "nullable": true,
                  "example": 50000
                },
                "prefer": {
                  "type": "string",
                  "example": "payflow"
                }
              }
            }
          },
          "obligations": {
            "type": "object",
            "description": "Пер-провайдерные требования (`daily_turnover_min/max`).",
            "additionalProperties": {
              "type": "object",
              "additionalProperties": true
            }
          },
          "rate_limits": {
            "type": "object",
            "description": "Пер-провайдерный rate limit (запросов в минуту).",
            "additionalProperties": {
              "type": "integer"
            }
          },
          "fallback_provider": {
            "type": "string",
            "description": "Имя self-провайдера, подхватывающего операции без допустимых внешних.",
            "example": "spacepayments"
          }
        }
      },
      "Report": {
        "type": "object",
        "description": "Формат идентичен `routing_report_test.json`. Собирается из SQL по\nтекущей выборке (с учётом фильтров GET /report).\n",
        "required": [
          "period",
          "total_operations",
          "strategy",
          "distribution",
          "volume_distribution",
          "attempt_distribution",
          "skip_reasons",
          "projected_daily_utilization",
          "fallback"
        ],
        "properties": {
          "period": {
            "type": "string",
            "description": "Дата или интервал, к которому относится отчёт",
            "example": "2026-07-30"
          },
          "total_operations": {
            "type": "integer",
            "minimum": 0,
            "example": 10
          },
          "strategy": {
            "type": "string",
            "example": "count_share"
          },
          "distribution": {
            "type": "object",
            "description": "Распределение по итоговому selected_provider.",
            "additionalProperties": {
              "$ref": "#/components/schemas/DistributionEntry"
            }
          },
          "volume_distribution": {
            "type": "object",
            "description": "Распределение по объёму (сумма amount у выбранного провайдера).",
            "additionalProperties": {
              "$ref": "#/components/schemas/VolumeDistributionEntry"
            }
          },
          "attempt_distribution": {
            "type": "object",
            "description": "Распределение по всем реальным попыткам (не только selected).",
            "additionalProperties": {
              "$ref": "#/components/schemas/AttemptDistributionEntry"
            }
          },
          "skip_reasons": {
            "type": "object",
            "description": "Счётчики причин отсева по всем attempts с `decision=skipped`.",
            "additionalProperties": {
              "type": "integer",
              "minimum": 0
            },
            "example": {
              "bank_not_in_list": 8,
              "amount_exceeds_limit": 3,
              "amount_below_minimum": 2
            }
          },
          "projected_daily_utilization": {
            "type": "object",
            "additionalProperties": {
              "$ref": "#/components/schemas/UtilizationEntry"
            }
          },
          "fallback": {
            "$ref": "#/components/schemas/FallbackStats"
          },
          "benchmark": {
            "$ref": "#/components/schemas/BenchmarkStats"
          },
          "deviation_causes": {
            "type": "array",
            "items": {
              "type": "string"
            },
            "description": "Пояснения к отклонениям от target (по одному на видимый deviation).",
            "example": []
          },
          "recommendations": {
            "type": "array",
            "items": {
              "type": "string"
            },
            "example": [
              "vipay: conversion_24h заявлена 0.87, наблюдаемая 0.78 — пересчитать по факту",
              "payflow: свободно 100 000 ₽ при среднем чеке 38 580 ₽ — снизить traffic_percentage 35 → 20"
            ]
          }
        }
      },
      "DistributionEntry": {
        "type": "object",
        "required": [
          "count",
          "share_pct",
          "target_pct",
          "achievable_pct",
          "deviation_pp"
        ],
        "properties": {
          "count": {
            "type": "integer",
            "minimum": 0,
            "example": 4
          },
          "share_pct": {
            "type": "number",
            "example": 40.0
          },
          "target_pct": {
            "type": "number",
            "example": 40
          },
          "achievable_pct": {
            "type": "number",
            "nullable": true,
            "example": 40.0
          },
          "deviation_pp": {
            "type": "number",
            "example": 0.0
          }
        }
      },
      "VolumeDistributionEntry": {
        "type": "object",
        "required": [
          "amount",
          "share_pct",
          "target_pct",
          "achievable_pct",
          "deviation_pp"
        ],
        "properties": {
          "amount": {
            "type": "integer",
            "minimum": 0,
            "example": 102000
          },
          "share_pct": {
            "type": "number",
            "example": 26.4
          },
          "target_pct": {
            "type": "number",
            "example": 40
          },
          "achievable_pct": {
            "type": "number",
            "nullable": true,
            "example": null
          },
          "deviation_pp": {
            "type": "number",
            "example": -13.6
          }
        }
      },
      "AttemptDistributionEntry": {
        "type": "object",
        "required": [
          "attempts",
          "successful",
          "observed_conversion"
        ],
        "properties": {
          "attempts": {
            "type": "integer",
            "minimum": 0,
            "example": 4
          },
          "successful": {
            "type": "integer",
            "minimum": 0,
            "example": 4
          },
          "observed_conversion": {
            "type": "number",
            "nullable": true,
            "description": "successful / attempts, null если attempts=0",
            "example": 1.0
          }
        }
      },
      "UtilizationEntry": {
        "type": "object",
        "required": [
          "used",
          "limit",
          "utilization_pct"
        ],
        "properties": {
          "used": {
            "type": "integer",
            "minimum": 0,
            "example": 2988800
          },
          "limit": {
            "type": "integer",
            "nullable": true,
            "description": "null, если daily_amount_limit не задан",
            "example": 3000000
          },
          "utilization_pct": {
            "type": "number",
            "nullable": true,
            "example": 99.6
          }
        }
      },
      "FallbackStats": {
        "type": "object",
        "required": [
          "first_attempt_success",
          "recovered_by_fallback",
          "fallback_rate_pct",
          "spacepayments_used",
          "cascade_exhausted"
        ],
        "properties": {
          "first_attempt_success": {
            "type": "integer",
            "minimum": 0,
            "example": 8
          },
          "recovered_by_fallback": {
            "type": "integer",
            "minimum": 0,
            "example": 0
          },
          "fallback_rate_pct": {
            "type": "number",
            "minimum": 0,
            "example": 0.0
          },
          "spacepayments_used": {
            "type": "integer",
            "minimum": 0,
            "example": 0
          },
          "cascade_exhausted": {
            "type": "integer",
            "minimum": 0,
            "example": 2
          }
        }
      },
      "BenchmarkStats": {
        "type": "object",
        "description": "Сравнение с офлайн-оптимумом (задача X-4). Не считается в потоковом режиме — секция может быть null.",
        "nullable": true,
        "properties": {
          "offline_bound": {
            "type": "object",
            "properties": {
              "max_deviation_pp": {
                "type": "number",
                "example": 5.0
              },
              "delivered": {
                "type": "integer",
                "example": 10
              }
            }
          },
          "our_online_result": {
            "type": "object",
            "properties": {
              "max_deviation_pp": {
                "type": "number",
                "example": 5.0
              },
              "delivered": {
                "type": "integer",
                "example": 10
              }
            }
          },
          "competitive_ratio": {
            "type": "number",
            "example": 1.0
          },
          "note": {
            "type": "string"
          }
        }
      },
      "State": {
        "type": "object",
        "required": [
          "gateway",
          "merchant",
          "strategy",
          "providers"
        ],
        "properties": {
          "gateway": {
            "type": "string",
            "example": "RUB_SBP_WITHDRAW"
          },
          "merchant": {
            "type": "string",
            "example": "alpha_market"
          },
          "strategy": {
            "type": "string",
            "example": "count_share"
          },
          "seed": {
            "type": "integer",
            "example": 42
          },
          "providers": {
            "type": "array",
            "items": {
              "type": "object",
              "required": [
                "payment_system",
                "in_progress_count",
                "in_progress_amount",
                "daily_approved_amount",
                "available_requisites"
              ],
              "properties": {
                "payment_system": {
                  "type": "string",
                  "example": "vipay"
                },
                "in_progress_count": {
                  "type": "integer",
                  "example": 4
                },
                "in_progress_amount": {
                  "type": "integer",
                  "example": 380000
                },
                "daily_approved_amount": {
                  "type": "integer",
                  "example": 3200000
                },
                "available_requisites": {
                  "type": "integer",
                  "example": 12
                },
                "share_bp": {
                  "type": "integer",
                  "description": "Текущая доля в базисных пунктах (10000 = 100%)",
                  "example": 4000
                }
              }
            }
          }
        }
      },
      "Health": {
        "type": "object",
        "required": [
          "status",
          "snapshot_loaded",
          "decisions_count",
          "retention_hours"
        ],
        "properties": {
          "status": {
            "type": "string",
            "enum": [
              "ok"
            ]
          },
          "snapshot_loaded": {
            "type": "boolean"
          },
          "decisions_count": {
            "type": "integer",
            "minimum": 0,
            "description": "Число строк в таблице decisions"
          },
          "retention_hours": {
            "type": "integer",
            "minimum": 1
          },
          "strategy": {
            "type": "string",
            "nullable": true
          },
          "version": {
            "type": "string"
          }
        }
      },
      "DecisionsListResponse": {
        "type": "object",
        "required": [
          "items",
          "total",
          "limit",
          "offset"
        ],
        "properties": {
          "items": {
            "type": "array",
            "items": {
              "$ref": "#/components/schemas/Decision"
            }
          },
          "total": {
            "type": "integer",
            "minimum": 0,
            "description": "Всего решений в выборке (без учёта limit/offset)"
          },
          "limit": {
            "type": "integer",
            "example": 100
          },
          "offset": {
            "type": "integer",
            "example": 0
          },
          "next_offset": {
            "type": "integer",
            "nullable": true,
            "description": "offset для следующей страницы или null, если это последняя"
          }
        }
      },
      "ContextOkResponse": {
        "type": "object",
        "required": [
          "status"
        ],
        "properties": {
          "status": {
            "type": "string",
            "enum": [
              "ok"
            ]
          },
          "providers_count": {
            "type": "integer",
            "minimum": 0
          },
          "gateway": {
            "type": "string"
          },
          "merchant": {
            "type": "string"
          },
          "strategy": {
            "type": "string"
          }
        }
      },
      "Error": {
        "type": "object",
        "required": [
          "error",
          "message"
        ],
        "properties": {
          "error": {
            "type": "string",
            "enum": [
              "validation_failed",
              "no_snapshot",
              "not_found",
              "internal_error"
            ],
            "description": "Стабильный код ошибки для программной обработки."
          },
          "message": {
            "type": "string",
            "description": "Человекочитаемое пояснение."
          },
          "details": {
            "type": "object",
            "description": "Произвольная структура с деталями. Форма зависит от кода.",
            "additionalProperties": true
          }
        }
      },
      "SnapshotRequest": {
        "type": "object",
        "description": "Совместим по форме с `reference/data/providers.json`. `snapshot_at`\nопционален (сервер использует своё текущее время, если не передан).\n",
        "required": [
          "gateway",
          "merchant",
          "providers"
        ],
        "properties": {
          "snapshot_at": {
            "type": "string",
            "format": "date-time",
            "nullable": true,
            "example": "2026-07-30T09:00:00+03:00"
          },
          "gateway": {
            "type": "string",
            "example": "RUB_SBP_WITHDRAW"
          },
          "merchant": {
            "type": "string",
            "example": "alpha_market"
          },
          "providers": {
            "type": "array",
            "minItems": 1,
            "items": {
              "$ref": "#/components/schemas/Provider"
            }
          }
        }
      },
      "ConfigRequest": {
        "type": "object",
        "required": [
          "config"
        ],
        "properties": {
          "config": {
            "$ref": "#/components/schemas/Config"
          }
        }
      },
      "BootstrapRequest": {
        "type": "object",
        "required": [
          "snapshot",
          "config"
        ],
        "description": "Оба поля обязательны. Порядок применения — сначала snapshot, потом config (эффект равен `POST /snapshot` + `POST /config`).",
        "properties": {
          "snapshot": {
            "$ref": "#/components/schemas/SnapshotRequest"
          },
          "config": {
            "$ref": "#/components/schemas/Config"
          }
        }
      },
      "OperationRequest": {
        "type": "object",
        "required": [
          "operation"
        ],
        "properties": {
          "operation": {
            "$ref": "#/components/schemas/Operation"
          }
        }
      },
      "OperationsBatchRequest": {
        "type": "object",
        "required": [
          "operations"
        ],
        "properties": {
          "operations": {
            "type": "array",
            "minItems": 1,
            "items": {
              "$ref": "#/components/schemas/Operation"
            }
          }
        }
      }
    },
    "examples": {
      "SnapshotRequestExample": {
        "summary": "Стандартный снапшот из reference/data/providers.json",
        "value": {
          "snapshot_at": "2026-07-30T09:00:00+03:00",
          "gateway": "RUB_SBP_WITHDRAW",
          "merchant": "alpha_market",
          "providers": [
            {
              "payment_system": "vipay",
              "status": "active",
              "traffic_percentage": 40,
              "priority": 1,
              "limit_amount_min": 1000,
              "limit_amount_max": 100000,
              "daily_amount_limit": 5000000,
              "daily_approved_amount": 3200000,
              "in_progress_count_limit": 10,
              "in_progress_count": 4,
              "in_progress_amount_limit": 1000000,
              "in_progress_amount": 380000,
              "available_requisites": 12,
              "conversion_24h": 0.87,
              "avg_latency_sec": 38,
              "banks": [
                "sberbank",
                "tinkoff",
                "vtb"
              ],
              "exclude_banks": false,
              "provider_margin_pct": 1.2,
              "merchant_margin_pct": 1.5,
              "allow_negative_agreement": false
            },
            {
              "payment_system": "spacepayments",
              "status": "active",
              "traffic_percentage": 0,
              "priority": 99,
              "limit_amount_min": null,
              "limit_amount_max": null,
              "daily_amount_limit": null,
              "daily_approved_amount": 0,
              "in_progress_count_limit": null,
              "in_progress_count": 0,
              "in_progress_amount_limit": null,
              "in_progress_amount": 0,
              "available_requisites": 8,
              "conversion_24h": 0.95,
              "avg_latency_sec": 15,
              "banks": [],
              "exclude_banks": false,
              "provider_margin_pct": 0.5,
              "merchant_margin_pct": 1.5,
              "allow_negative_agreement": false,
              "note": "self-provider, используется только как fallback"
            }
          ]
        }
      },
      "ConfigRequestExample": {
        "summary": "Стандартный конфиг из config/routing.yml (в JSON-виде)",
        "value": {
          "config": {
            "strategy": "count_share",
            "layers": [],
            "goals": {
              "budget_headroom": {
                "psi_threshold_micro": 100000
              },
              "share_ceiling": {
                "tolerance_bp": 0
              }
            },
            "outcomes": {
              "source": "deterministic",
              "seed": 42,
              "calibrate_from_history": true
            },
            "amount_ranges": [
              {
                "from": 500,
                "to": 50000,
                "prefer": "payflow"
              },
              {
                "from": 50001,
                "to": 100000,
                "prefer": "vipay"
              },
              {
                "from": 100001,
                "to": null,
                "prefer": "quickpay"
              }
            ],
            "obligations": {
              "payflow": {
                "daily_turnover_min": 2000000
              },
              "vipay": {
                "daily_turnover_max": 5000000
              }
            },
            "rate_limits": {
              "vipay": 7,
              "quickpay": 15
            },
            "fallback_provider": "spacepayments"
          }
        }
      },
      "BootstrapRequestExample": {
        "summary": "snapshot + config одним запросом",
        "value": {
          "snapshot": {
            "gateway": "RUB_SBP_WITHDRAW",
            "merchant": "alpha_market",
            "providers": [
              {
                "payment_system": "vipay",
                "status": "active",
                "traffic_percentage": 40,
                "priority": 1,
                "limit_amount_min": 1000,
                "limit_amount_max": 100000,
                "daily_amount_limit": 5000000,
                "daily_approved_amount": 3200000,
                "in_progress_count_limit": 10,
                "in_progress_count": 4,
                "in_progress_amount_limit": 1000000,
                "in_progress_amount": 380000,
                "available_requisites": 12,
                "conversion_24h": 0.87,
                "avg_latency_sec": 38,
                "banks": [
                  "sberbank",
                  "tinkoff",
                  "vtb"
                ],
                "exclude_banks": false,
                "provider_margin_pct": 1.2,
                "merchant_margin_pct": 1.5,
                "allow_negative_agreement": false
              }
            ]
          },
          "config": {
            "strategy": "count_share",
            "layers": [],
            "outcomes": {
              "source": "deterministic",
              "seed": 42,
              "calibrate_from_history": true
            },
            "fallback_provider": "spacepayments"
          }
        }
      },
      "OperationRequestExample": {
        "summary": "Одна операция (op_106 из тестовой очереди)",
        "value": {
          "operation": {
            "operation_id": "op_106",
            "created_at": "2026-07-30T09:07:30+03:00",
            "amount": 52000,
            "bank": "sberbank",
            "card_brand": null,
            "payout_requisite": {
              "sbp": {
                "phone": "79005556677",
                "bank_name": "Сбербанк"
              }
            }
          }
        }
      },
      "OperationsBatchRequestExample": {
        "summary": "Пачка операций",
        "value": {
          "operations": [
            {
              "operation_id": "op_101",
              "created_at": "2026-07-30T09:05:00+03:00",
              "amount": 15000,
              "bank": "sberbank",
              "card_brand": null,
              "payout_requisite": {
                "sbp": {
                  "phone": "79001234567",
                  "bank_name": "Сбербанк"
                }
              }
            },
            {
              "operation_id": "op_102",
              "created_at": "2026-07-30T09:05:30+03:00",
              "amount": 48000,
              "bank": "alfa",
              "card_brand": null,
              "payout_requisite": {
                "sbp": {
                  "phone": "79007654321",
                  "bank_name": "Альфа-Банк"
                }
              }
            }
          ]
        }
      }
    }
  }
};
