# Set top-level scalar values of a flat JSON settings file in place (CONTROL Resonant's renderer.ini: one "key": value
# per line, tab-indented). Only the value text of the named line changes: every other byte, the key order and the number
# formats stay as they are. Each key must occur on exactly one line and the value must be a JSON number, true or false,
# else nothing is written. The result is parsed as JSON before it replaces the file.
# Usage: python3 -I flatjson_set.py FILE                   (print every key = value)
#        python3 -I flatjson_set.py FILE KEY=VALUE ...     (set them; VALUE as JSON: 1920, 60.0, true)
import json
import re
import sys

path, pairs = sys.argv[1], sys.argv[2:]
text = open(path, 'rb').read().decode('utf-8')
line = re.compile(r'^\s*"([^"]+)":\s*([^\r\n,]*?)\s*,?\r?$', re.M)
if not pairs:
    for key, value in line.findall(text):
        print('%s = %s' % (key, value))
    sys.exit(0)
for pair in pairs:
    key, value = pair.split('=', 1)
    try:
        parsed = json.loads(value)
    except ValueError:
        sys.exit('%s: %r is not a JSON number or true/false' % (key, value))
    if isinstance(parsed, (str, list, dict)) or parsed is None:
        sys.exit('%s: only numbers and true/false are set here' % key)
    pat = re.compile(r'^(\s*"%s":\s*)[^\r\n,]*?(\s*,?\r?)$' % re.escape(key), re.M)
    text, n = pat.subn(lambda m: m.group(1) + value + m.group(2), text)
    if n != 1:
        sys.exit('%s: %d lines, expected 1' % (key, n))
json.loads(text)
open(path, 'wb').write(text.encode('utf-8'))
