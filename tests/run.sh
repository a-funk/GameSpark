#!/bin/bash
# Offline checks: shell syntax, Python self-tests, and shellcheck when installed. Runs anywhere (no Spark needed).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT" || exit 1
fail=0
mapfile -t SH < <(git ls-files '*.sh' 2>/dev/null)
[ ${#SH[@]} -gt 0 ] || mapfile -t SH < <(find . -name '*.sh' -not -path './.git/*')
for f in "${SH[@]}"; do
  bash -n "$f" || { echo "syntax: $f"; fail=1; }
done
for t in bench/ingest.py bench/tune.py profile/analyze.py tools/steamcfg.py tools/winereg.py; do
  out=$(python3 -I "$t" --selftest 2>&1) && echo "ok   $t" || { echo "FAIL $t"; echo "$out"; fail=1; }
done
for f in bench/telemetry.py bench/cyberpunk2077_settings.py controller/xbox-watch.py tools/xinput.py; do
  python3 -I -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$f" || { echo "parse: $f"; fail=1; }
done
if command -v shellcheck >/dev/null; then shellcheck -x -S warning "${SH[@]}" && echo "ok   shellcheck" || fail=1; fi
[ $fail = 0 ] && echo "all checks passed"; exit $fail
