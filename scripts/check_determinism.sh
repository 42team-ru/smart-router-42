#!/usr/bin/env bash
# Проверяет отсутствие источников недетерминизма (rand/shuffle/sample/Time.now)
# в решающем пути: lib/routing и lib/execution.
#
# Падает с exit 2, если проверяемого каталога нет — переименование или удаление
# каталога не должно молча превращать проверку в вечно зелёную.
# Падает с exit 1, если найден источник случайности.
set -euo pipefail

DIRS=(lib/routing lib/execution)
PATTERN='\b(rand|shuffle|sample)\b|Time\.now'

for dir in "${DIRS[@]}"; do
  if [ ! -d "$dir" ]; then
    echo "отсутствует каталог $dir"
    exit 2
  fi
done

found=0
for dir in "${DIRS[@]}"; do
  if matches=$(grep -rnE "$PATTERN" -- "$dir"); then
    echo "$matches"
    found=1
  fi
done

if [ "$found" -eq 1 ]; then
  exit 1
fi

echo "детерминизм: источников случайности нет"
exit 0
