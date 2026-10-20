# shellcheck shell=bash
# Helpers for the per-game settings scripts (profiles/settings/<appid>/apply.sh) and bench adapters. Source it.
# Every change is backed up first, under $SG_DATA/backups/<appid>/ (GameSpark's own files: backups/gamespark/), and each
# backup gets a line in MANIFEST-settings.txt: UTC time, ORIGINAL or BEFORE, path, backup, sha256, why (tab-separated).
# The first backup of a file is its ORIGINAL, the state before GameSpark's first change; sg_revert puts that back.
: "${SG_DATA:=$HOME/.local/share/gamespark}"

sg_original() {   # APPID FILE: the backup of FILE's original state, if one was taken
  awk -F'\t' -v f="$2" '$2 == "ORIGINAL" && $3 == f { print $4; exit }' \
    "$SG_DATA/backups/$1/MANIFEST-settings.txt" 2>/dev/null
}

sg_backup() {   # APPID FILE WHY: back FILE up, print the backup's path
  local appid=$1 file=$2 why=$3 dir ts b kind
  dir=$SG_DATA/backups/$appid
  mkdir -p "$dir" || return 1
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  b=$dir/$(basename "$file").$ts
  [ -e "$b" ] && b=$b.$RANDOM
  cp -p "$file" "$b" || return 1
  if [ -n "$(sg_original "$appid" "$file")" ]; then kind=BEFORE; else kind=ORIGINAL; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$kind" "$file" "$b" "$(sha256sum "$b" | cut -d' ' -f1)" "$why" \
    >> "$dir/MANIFEST-settings.txt"
  echo "$b"
}

sg_revert() {   # APPID FILE: put FILE back as it was before GameSpark's first change
  local b
  b=$(sg_original "$1" "$2")
  [ -n "$b" ] && [ -f "$b" ] || { echo "no original backup of $2 (app $1)" >&2; return 1; }
  cp -p "$b" "$2" && echo "restored $2 from $b"
}
