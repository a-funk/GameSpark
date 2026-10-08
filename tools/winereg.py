"""Set values in a Wine/Proton prefix's user.reg (HKEY_CURRENT_USER). The game and its wineserver must be stopped
first: Wine rewrites user.reg on exit. Digits are written as DWORDs, anything else as a string, and "-" deletes the
value (ponytail: no way to write a numeric string; add a str: prefix if one is ever needed). A missing key is created.

  python3 -I tools/winereg.py PFX_DIR 'Software\\Vendor\\Game\\Graphics' Name=1 Other=0 ...
  python3 -I tools/winereg.py PFX_DIR 'Software\\Wine\\Explorer' Desktop=Default      (Desktop=- to remove)
  python3 -I tools/winereg.py --selftest
"""
import re
import shutil
import sys
import time


def set_values(user_reg, key, values):
    text = open(user_reg, encoding="utf-8", errors="surrogateescape").read()
    head = "[" + key.replace("\\", "\\\\") + "]"
    start = text.find(head)
    if start < 0:   # new key at the end, with the modification time Wine writes after the name
        text = text.rstrip("\n") + f"\n\n{head} {int(time.time())}\n"
        start = text.find(head)
    end = text.find("\n[", start + 1)
    end = len(text) if end < 0 else end
    section = text[start:end]
    for name, val in values.items():
        pat = re.compile(r'^"' + re.escape(name) + r'"=.*\n?', re.M)
        if val == "-":
            section = pat.sub("", section)
            continue
        line = f'"{name}"=dword:{int(val):08x}' if val.isdigit() else \
            '"%s"="%s"' % (name, val.replace("\\", "\\\\").replace('"', '\\"'))
        section = pat.sub(line + "\n", section) if pat.search(section) else section.rstrip("\n") + "\n" + line + "\n"
    section = section.rstrip("\n") + "\n"
    shutil.copy(user_reg, f"{user_reg}.bak-{int(time.time())}")
    open(user_reg, "w", encoding="utf-8", errors="surrogateescape").write(text[:start] + section + text[end:])


def selftest():
    import os
    import tempfile
    p = os.path.join(tempfile.mkdtemp(), "user.reg")
    open(p, "w").write('WINE REGISTRY Version 2\n\n[Software\\\\A\\\\G] 1\n"VSync"=dword:00000001\n"X"=dword:00000002\n\n[Software\\\\B] 2\n"VSync"=dword:00000001\n')
    set_values(p, "Software\\A\\G", {"VSync": "0", "EnableDX12": "1"})
    t = open(p).read()
    assert '"VSync"=dword:00000000' in t and '"EnableDX12"=dword:00000001' in t and '"X"=dword:00000002' in t, t
    assert t.count('"VSync"=dword:00000001') == 1  # other key untouched
    set_values(p, "Software\\Wine\\Explorer", {"Desktop": "Default"})      # new key, string value
    set_values(p, "Software\\A\\G", {"X": "-"})                             # delete a value
    t = open(p).read()
    assert '[Software\\\\Wine\\\\Explorer] ' in t and '"Desktop"="Default"' in t and '"X"=' not in t, t
    assert '\n\n[Software\\\\B] 2' in t, t                                  # neighbouring key keeps its spacing
    print("ok")


if __name__ == "__main__":
    if sys.argv[1] == "--selftest":
        selftest()
    else:
        pfx, key, *pairs = sys.argv[1:]
        set_values(pfx.rstrip("/") + "/user.reg", key, dict(p.split("=", 1) for p in pairs))
        print(f"{key}: " + ", ".join(pairs))
