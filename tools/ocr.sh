#!/bin/bash
# Read text from a screenshot with tesseract (installed, or a small local Docker image built on first use).
# Usage: tools/ocr.sh IMAGE               print the text
#        tools/ocr.sh IMAGE --find WORD   print "x y" (screen pixels) of the first word matching WORD, exit 1 if absent
set -u
IMG=$(cd "$(dirname "$1")" && pwd)/$(basename "$1"); shift
ocr() {
  if command -v tesseract >/dev/null; then tesseract "$IMG" - "$@" 2>/dev/null
  else
    docker image inspect gamespark-ocr >/dev/null 2>&1 || printf 'FROM ubuntu:24.04\nRUN apt-get update && apt-get install -y --no-install-recommends tesseract-ocr && rm -rf /var/lib/apt/lists/*\n' \
      | docker build -q -t gamespark-ocr - >/dev/null
    docker run --rm -v "$(dirname "$IMG"):/w:ro" gamespark-ocr tesseract "/w/$(basename "$IMG")" - "$@" 2>/dev/null
  fi
}
if [ "${1:-}" = --find ]; then
  ocr tsv | awk -F'\t' -v w="$2" 'NR > 1 && $12 ~ w { print int($7 + $9 / 2), int($8 + $10 / 2); found = 1; exit } END { exit !found }'
else
  ocr
fi
