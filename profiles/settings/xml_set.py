# Set values in a RAGE settings XML (Red Dead Redemption 2's system.xml) in place. Two forms occur:
#   <key value="0.350000" />          attribute form: the value is a number, true or false
#   <key>kSettingLevel_Low</key>      text form: the value is a kSetting* token
# Each KEY must occur exactly once (the element names are unique in the file) and the new value must suit the element's
# form, else nothing is written. Only the value text changes: line ends, indentation and every other byte stay as they are,
# and the result is parsed as XML before it replaces the file.
# Usage: python3 -I xml_set.py FILE                   (print every KEY = value)
#        python3 -I xml_set.py FILE KEY=VALUE ...     (set them)
import os
import re
import sys
import tempfile
import xml.etree.ElementTree as ET

path, pairs = sys.argv[1], sys.argv[2:]
text = open(path, 'rb').read().decode('utf-8')
if not pairs:
    for key, value in re.findall(r'<([A-Za-z0-9_]+) value="([^"]*)" />', text):
        print('%s = %s' % (key, value))
    for key, value in re.findall(r'<([A-Za-z0-9_]+)>([^<]*)</\1>', text):
        print('%s = %s' % (key, value))
    sys.exit(0)
for pair in pairs:
    key, sep, value = pair.partition('=')
    if not sep or not re.fullmatch(r'[A-Za-z0-9_]+', key):
        sys.exit('%s: expected KEY=VALUE' % pair)
    attr = re.compile(r'(<%s value=")([^"]*)(" />)' % key)
    body = re.compile(r'(<%s>)([^<]*)(</%s>)' % (key, key))
    n_attr, n_body = len(attr.findall(text)), len(body.findall(text))
    if n_attr + n_body != 1:
        sys.exit('%s: %d elements, expected 1' % (key, n_attr + n_body))
    if n_attr:
        if not re.fullmatch(r'-?[0-9]+(\.[0-9]+)?|true|false', value):
            sys.exit('%s: %r is not a number, true or false' % (key, value))
        text = attr.sub(lambda m: m.group(1) + value + m.group(3), text)
    else:
        if not re.fullmatch(r'kSetting[A-Za-z0-9_]+', value):
            sys.exit('%s: %r is not a kSetting token' % (key, value))
        text = body.sub(lambda m: m.group(1) + value + m.group(3), text)
ET.fromstring(text.encode('utf-8'))   # still well-formed
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(path)), prefix='.xml_set.')
with os.fdopen(fd, 'wb') as f:
    f.write(text.encode('utf-8'))
os.chmod(tmp, os.stat(path).st_mode & 0o7777)
os.replace(tmp, path)
