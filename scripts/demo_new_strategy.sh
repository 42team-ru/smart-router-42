#!/usr/bin/env bash
# Демо на минуту защиты: новая стратегия = файл в lib/routing/strategies/
# плюс строка strategy: в конфиге. Ядро не правится: ни bin/route, ни реестр,
# ни Planner о новом имени не знают.
#
# Скрипт временно пишет в lib/, поэтому в make check он не входит и запускается
# руками. Копия удаляется trap'ом при любом исходе, включая Ctrl+C и падение;
# после уборки каталог обязан вернуться к семи стратегиям, иначе выход не 0.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

EXAMPLE='docs/examples/reverse_priority.rb'
INSTALLED='lib/routing/strategies/reverse_priority.rb'
QUEUE='reference/data/operations_queue_10.json'
TMP="$(mktemp -d)"

cleanup() {
  rm -f "$INSTALLED"
  rm -rf "$TMP"
}
trap cleanup EXIT

known() {
  ruby -Ilib -e 'require "routing/strategies"
                 names = Routing::Strategies.load_all!
                 puts "#{names.size}: #{names.join(", ")}"'
}

split() {
  ruby -rjson -e 'd = JSON.parse(File.read(ARGV[0]))
                  h = Hash.new(0)
                  d.each { |x| h[x["selected_provider"]] += 1 }
                  puts h.sort.map { |k, v| "#{k}=#{v}" }.join(" ")' "$1"
}

echo '== 1. Реестр до добавления файла =='
known

echo
echo "== 2. Кладём $EXAMPLE в lib/routing/strategies/ =="
cp "$EXAMPLE" "$INSTALLED"
known

echo
echo '== 3. Одна строка в конфиге: strategy: count_share -> strategy: reverse_priority =='
# Боевой config/routing.yml не изменяется: правится копия во временном каталоге.
# Ключ comparison требует, чтобы один из вариантов совпадал с боевой стратегией,
# а демо её как раз подменяет — вырезаем блок, он к демонстрации не относится.
sed 's/^strategy: count_share$/strategy: reverse_priority/' config/routing.yml \
  | sed '/^comparison:/,/^[^ -]/{/^comparison:/d; /^[[:space:]]*-/d;}' >"$TMP/routing.yml"
grep -E '^strategy:' "$TMP/routing.yml"
bundle exec bin/route "$QUEUE" --config "$TMP/routing.yml" --out-dir "$TMP" >/dev/null
echo -n 'распределение reverse_priority: '
split "$TMP/routing_decisions_test.json"

echo
echo '== 4. Валидатор организаторов =='
set +e
ruby reference/scripts/validate_10.rb "$TMP/routing_decisions_test.json" | tail -5
validator_status=${PIPESTATUS[0]}
set -e

echo
echo '== 5. Убираем файл — реестр возвращается к исходному состоянию =='
rm -f "$INSTALLED"
known

if [ "$validator_status" -ne 0 ]; then
  echo 'ПРОВАЛ: валидатор организаторов вернул ненулевой код' >&2
  exit 1
fi

if [ -e "$INSTALLED" ]; then
  echo "ПРОВАЛ: после уборки остался $INSTALLED" >&2
  exit 1
fi

# Проверяем именно неотслеживаемые файлы в каталоге стратегий: это то, что
# оставляет после себя упавшее демо. Уже изменённые файлы репозитория — не
# наша забота и не повод считать демо провалившимся.
leftovers="$(git status --porcelain lib/routing/strategies | grep '^??' || true)"
if [ -n "$leftovers" ]; then
  echo 'ПРОВАЛ: демо оставило файлы в lib/routing/strategies:' >&2
  echo "$leftovers" >&2
  exit 1
fi

echo
echo 'демо: OK'
