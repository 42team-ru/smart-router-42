# Единственная точка входа для агентов и людей.
#
#   make gate      ворота: спеки + линтер. Определение готовности любой задачи
#   make validate  валидатор организаторов на публичной очереди
#   make route     боевой прогон, q=<файл очереди>
#
# Гейт и валидатор — разные вещи. Гейт говорит «наш код не сломан»,
# валидатор — «наш вывод примут». Зелёными должны быть оба.

.DEFAULT_GOAL := gate

QUEUE ?= reference/data/operations_queue_10.json
OUT   ?= out/routing_decisions_test.json

.PHONY: gate test lint fmt validate route determinism no-random install deliver help install-swagger-ui openapi-check openapi-embed serve

gate: test lint no-random

test:
	bundle exec rspec

lint:
	bundle exec rubocop

fmt:
	bundle exec rubocop -A

route:
	bundle exec bin/route $(QUEUE)

# Валидатор организаторов жёстко читает reference/data/operations_queue_10.json
# (строки 18-19 скрипта), поэтому цель не зависит от $(QUEUE) и не параметризуется.
validate:
	bundle exec bin/route reference/data/operations_queue_10.json
	ruby reference/scripts/validate_10.rb $(OUT)

# Единственная команда часа стопкода: кладёт боевые имена файлов в корень репозитория.
deliver:
	bundle exec bin/route $(QUEUE) --out-dir .

# Два прогона обязаны совпасть побайтово. Невоспроизводимость убивает
# главную цифру защиты, поэтому проверяется отдельной целью.
determinism:
	@bundle exec bin/route $(QUEUE) && cp $(OUT) /tmp/run1.json
	@bundle exec bin/route $(QUEUE) && cp $(OUT) /tmp/run2.json
	@diff -q /tmp/run1.json /tmp/run2.json && echo "детерминизм: OK"

# Статическая проверка: в решающем пути (lib/routing, lib/execution) не должно быть
# rand/shuffle/sample/Time.now. Падает и когда каталог переименован/удалён.
no-random:
	@bash scripts/check_determinism.sh

install:
	bundle install

help:
	@echo "gate test lint fmt validate route determinism no-random install deliver"
	@echo "openapi-check openapi-embed install-swagger-ui serve"

# HTTP-сервис. Puma workers=1 threads=1 — детерминизм гарантирован конструкцией.
# Порт: config/service.yml (или PORT=...); Swagger UI на /swagger.
serve:
	bundle exec bin/serve

# Проверка синтаксиса OpenAPI-спеки (только YAML-парсинг, без semantic-валидации).
openapi-check:
	@ruby -e 'require "yaml"; d = YAML.load_file("docs/openapi.yaml"); \
	  raise "openapi: field missing" unless d["openapi"]; \
	  raise "paths: empty" if d["paths"].to_h.empty?; \
	  raise "components.schemas: empty" if d.dig("components","schemas").to_h.empty?; \
	  puts "openapi.yaml: OK (#{d["openapi"]}, paths=#{d["paths"].keys.length}, schemas=#{d["components"]["schemas"].keys.length})"'

# Пересобирает public/swagger/openapi-spec.js из docs/openapi.yaml.
# Нужно каждый раз после правки спеки, чтобы file:// preview показывал свежее.
# При http:// (запущенный сервис) файл безобиден — Sinatra отдаёт /openapi.yaml напрямую.
openapi-embed: openapi-check
	@ruby scripts/embed_openapi.rb

# Idempotent: обновляет только asset-файлы swagger-ui, наши патчи в
# index.html и swagger-initializer.js остаются нетронутыми.
SWAGGER_UI_VERSION ?= 5.32.15
install-swagger-ui:
	@echo "Downloading swagger-ui-dist $(SWAGGER_UI_VERSION)..."
	@mkdir -p public/swagger /tmp/swagger-ui-extract
	@curl -sfL https://registry.npmjs.org/swagger-ui-dist/-/swagger-ui-dist-$(SWAGGER_UI_VERSION).tgz -o /tmp/swagger-ui.tgz
	@tar -xzf /tmp/swagger-ui.tgz --strip-components=1 -C /tmp/swagger-ui-extract
	@cp /tmp/swagger-ui-extract/swagger-ui.css                  public/swagger/
	@cp /tmp/swagger-ui-extract/swagger-ui-bundle.js            public/swagger/
	@cp /tmp/swagger-ui-extract/swagger-ui-standalone-preset.js public/swagger/
	@cp /tmp/swagger-ui-extract/index.css                       public/swagger/
	@cp /tmp/swagger-ui-extract/favicon-16x16.png               public/swagger/
	@cp /tmp/swagger-ui-extract/favicon-32x32.png               public/swagger/
	@cp /tmp/swagger-ui-extract/LICENSE                         public/swagger/
	@rm -rf /tmp/swagger-ui.tgz /tmp/swagger-ui-extract
	@echo "Готово. index.html и swagger-initializer.js сохранены (наши патчи)."
	@echo "Открой public/swagger/index.html в браузере (file://) для preview."
