#!/usr/bin/env bash
# e2e-проверка: /operations/batch на очереди даёт байт-в-байт то же, что bin/route.
# Гарантия детерминизма и валидности инвариантов проекта.
#
# Использование:
#   scripts/compare_batch_vs_cli.sh                                  # 10-очередь
#   scripts/compare_batch_vs_cli.sh path/to/queue.json               # своя
#   PORT=5000 scripts/compare_batch_vs_cli.sh                        # др. порт
#
# Требует уже поднятый bin/serve на PORT (по умолчанию 4567).

set -euo pipefail

QUEUE_PATH="${1:-reference/data/operations_queue_10.json}"
PROVIDERS_PATH="${PROVIDERS_PATH:-reference/data/providers.json}"
PORT="${PORT:-4567}"
BASE_URL="http://localhost:${PORT}"

if [[ ! -f "$QUEUE_PATH" ]]; then
  echo "queue file not found: $QUEUE_PATH" >&2
  exit 1
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# 1. Прогоняем CLI как эталон.
bundle exec bin/route "$QUEUE_PATH" --out-dir "$TMPDIR/cli" >/dev/null
CLI_DECISIONS="$TMPDIR/cli/routing_decisions_test.json"

# 2. Собираем snapshot+config+операции для сервиса.
export SNAPSHOT_PATH="$PROVIDERS_PATH"
export ROUTING_YAML_PATH="config/routing.yml"
export QUEUE_JSON_PATH="$QUEUE_PATH"

BOOTSTRAP_OUT="$TMPDIR/bootstrap.json" \
BATCH_OUT="$TMPDIR/batch.json" \
ruby -ryaml -rjson -e '
snap = JSON.parse(File.read(ENV["SNAPSHOT_PATH"]))
cfg  = YAML.load_file(ENV["ROUTING_YAML_PATH"])
File.write(ENV["BOOTSTRAP_OUT"], JSON.generate({snapshot: snap, config: cfg}))
File.write(ENV["BATCH_OUT"], JSON.generate({operations: JSON.parse(File.read(ENV["QUEUE_JSON_PATH"]))}))
'

# 3. Bootstrap + batch.
curl -sf -X POST "$BASE_URL/bootstrap" \
  -H 'Content-Type: application/json' \
  --data @"$TMPDIR/bootstrap.json" >/dev/null

curl -sf -X POST "$BASE_URL/operations/batch" \
  -H 'Content-Type: application/json' \
  --data @"$TMPDIR/batch.json" > "$TMPDIR/batch_response.json"

# 4. Приводим ответ /operations/batch к формату CLI (просто массив decisions)
#    и сверяем побайтно через каноничный JSON.
ruby -rjson -e '
data = JSON.parse(File.read(ARGV[0]))
decisions = data.fetch("decisions")
File.write(ARGV[1], JSON.pretty_generate(decisions))
' "$TMPDIR/batch_response.json" "$TMPDIR/service.json"

ruby -rjson -e '
cli = JSON.parse(File.read(ARGV[0]))
srv = JSON.parse(File.read(ARGV[1]))
if cli == srv
  puts "compare_batch_vs_cli: OK (%d decisions match)" % cli.size
  exit 0
else
  $stderr.puts "compare_batch_vs_cli: MISMATCH"
  $stderr.puts "cli size:     %d" % cli.size
  $stderr.puts "service size: %d" % srv.size
  exit 1
end
' "$CLI_DECISIONS" "$TMPDIR/service.json"
