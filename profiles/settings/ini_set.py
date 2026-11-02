# Set KEY=VALUE lines of an INI file in place. Line endings (CRLF in CAPCOM's config.ini) and every other line stay as
# they are. Each KEY must occur exactly once, else nothing is written.
# Usage: python3 -I ini_set.py FILE KEY=VALUE [KEY=VALUE ...]
import sys

path, pairs = sys.argv[1], sys.argv[2:]
lines = open(path, 'rb').read().split(b'\n')
for pair in pairs:
    key, value = pair.split('=', 1)
    prefix = key.encode() + b'='
    hits = [i for i, line in enumerate(lines) if line.rstrip(b'\r').startswith(prefix)]
    if len(hits) != 1:
        sys.exit('%s: %d lines, expected 1' % (key, len(hits)))
    i = hits[0]
    eol = lines[i][len(lines[i].rstrip(b'\r')):]
    lines[i] = prefix + value.encode() + eol
open(path, 'wb').write(b'\n'.join(lines))
