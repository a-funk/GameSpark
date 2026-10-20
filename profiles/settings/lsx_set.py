# Set ConfigEntry values in a Larian graphicSettings.lsx (XML: <node id="ConfigEntry"> with MapKey, Type and Value
# attributes). Each MapKey must occur exactly once, else nothing is written; nothing else in the file changes.
# Usage: python3 -I lsx_set.py FILE                   (print every MapKey = Value)
#        python3 -I lsx_set.py FILE MapKey=VALUE ...  (set them)
import re
import sys

ENTRY = re.compile(
    r'<node id="ConfigEntry">\s*<attribute id="MapKey" value="([^"]*)" [^>]*/>\s*'
    r'<attribute id="Type" [^>]*/>\s*<attribute id="Value" value="([^"]*)" [^>]*/>')

path, pairs = sys.argv[1], sys.argv[2:]
text = open(path, 'rb').read().decode('utf-8')
if not pairs:
    for key, value in ENTRY.findall(text):
        print('%s = %s' % (key, value))
    sys.exit(0)
for pair in pairs:
    key, value = pair.split('=', 1)
    pat = re.compile(
        r'(<node id="ConfigEntry">\s*<attribute id="MapKey" value="%s" [^>]*/>\s*'
        r'<attribute id="Type" [^>]*/>\s*<attribute id="Value" value=")([^"]*)(")' % re.escape(key))
    text, n = pat.subn(lambda m: m.group(1) + value + m.group(3), text)
    if n != 1:
        sys.exit('%s: %d entries, expected 1' % (key, n))
open(path, 'wb').write(text.encode('utf-8'))
