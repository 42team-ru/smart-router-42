#!/usr/bin/env bash
# Сравнение конфигураций роутинга на синтетике.
#
#   scripts/bench_configs.sh                    все зарегистрированные стратегии
#   scripts/bench_configs.sh a.yml b.yml        конкретные конфиги
#
# Гоняет уровень compare — он стоит на профиле competitive, где 94% заявок
# допускают пятерых провайдеров, поэтому стратегия действительно решает, кому
# уйдёт заявка. На остальных уровнях выбор сужен hard-constraints (до 70%
# заявок имеют ровно одного кандидата), и любые конфиги дают там один и тот же
# результат — сравнивать нечего.
#
# Важно: bin/bench всегда берёт детерминированный источник исходов с seed из
# CLI, ключ outcomes из конфига не применяется. Сравниваются стратегии, слои и
# селектор, а не модель исходов.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

LEVEL=compare
SEED="${SEED:-1}"
DIR="tmp/bench/$LEVEL"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ -f "$DIR/queue.json" ] || bundle exec ruby bin/gen --level "$LEVEL" --seed "$SEED" --out-dir "$DIR" >/dev/null

configs=("$@")
if [ ${#configs[@]} -eq 0 ]; then
  # Ни одного аргумента — собираем по конфигу на каждую стратегию из реестра.
  while read -r name; do
    printf 'strategy: %s\nlayers: []\nfallback_provider: spacepayments\n' "$name" > "$TMP/$name.yml"
    configs+=("$TMP/$name.yml")
  done < <(bundle exec ruby -e '$LOAD_PATH.unshift("lib"); require "routing/strategies"; puts Routing::Strategies.load_all!')
fi

printf '%-22s %10s %9s %9s %8s\n' конфиг доставлено spacepay откл_пп ratio
for cfg in "${configs[@]}"; do
  # Ненулевой код выхода означает вердикт ПРОВАЛ, а не сбой запуска: строку
  # всё равно печатаем, иначе конфиг с необычным распределением просто исчезал
  # бы из таблицы вместо того, чтобы показать свои числа.
  out=$(bundle exec ruby bin/bench --level "$LEVEL" --seed "$SEED" --dir "$DIR" --config "$cfg" 2>&1) || true
  if ! grep -q 'ВЕРДИКТ' <<<"$out"; then
    printf '%-22s %s\n' "$(basename "$cfg" .yml)" 'не запустился'
    continue
  fi
  delivered=$(grep -oP 'доставлено: \K[0-9]+' <<<"$out" | head -1)
  space=$(grep -oP '\K[0-9]+(?= в spacepayments)' <<<"$out")
  dev=$(grep -oP 'наш прогон: доставлено [0-9]+, отклонение \K[0-9.]+' <<<"$out")
  ratio=$(grep -oP 'competitive_ratio: \K.+' <<<"$out")
  printf '%-22s %10s %9s %9s %8s\n' "$(basename "$cfg" .yml)" "$delivered" "$space" "${dev:-—}" "${ratio:-—}"
done
