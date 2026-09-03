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

.PHONY: gate test lint fmt validate route determinism no-random install deliver help

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
