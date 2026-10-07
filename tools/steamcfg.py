"""Edit Steam's per-game settings in its VDF files. Steam must be closed: it rewrites these files on exit.
Prefer tools/steam-config.sh, which closes and restarts Steam around the edit.

  steamcfg.py launch-options LOCALCONFIG APPID "OPTIONS"   userdata/<id>/config/localconfig.vdf; "" clears
  steamcfg.py compat-tool    CONFIG      APPID TOOL        config/config.vdf; TOOL e.g. proton_experimental, "" clears
  steamcfg.py --selftest
"""
import re
import shutil
import sys
import time


def tokenize(text):
    return [m.group(1) if m.group(1) is not None else m.group(2) for m in re.finditer(r'"((?:[^"\\]|\\.)*)"|([{}])', text)]


def parse(tokens, i=0):
    node = []
    while i < len(tokens):
        if tokens[i] == "}":
            return node, i + 1
        key = tokens[i]
        i += 1
        if tokens[i] == "{":
            sub, i = parse(tokens, i + 1)
            node.append([key, sub])
        else:
            node.append([key, tokens[i]])
            i += 1
    return node, i


def dump(node, depth=0):
    out = []
    for k, v in node:
        if isinstance(v, list):
            out += ["\t" * depth + f'"{k}"', "\t" * depth + "{", *dump(v, depth + 1), "\t" * depth + "}"]
        else:
            out.append("\t" * depth + f'"{k}"\t\t"{v}"')
    return out


def child(node, key):
    for kv in node:
        if kv[0].lower() == key.lower() and isinstance(kv[1], list):
            return kv[1]
    new = []
    node.append([key, new])
    return new


def edit(path, keys, fn):
    """Apply fn to the node at keys (created if missing), back up, write, and verify the round trip."""
    tree, _ = parse(tokenize(open(path, encoding="utf-8").read()))
    node = tree
    for k in keys:
        node = child(node, k)
    fn(node)
    shutil.copy(path, f"{path}.bak-{int(time.time())}")
    text = "\n".join(dump(tree)) + "\n"
    open(path, "w", encoding="utf-8").write(text)
    assert tokenize(open(path, encoding="utf-8").read()) == tokenize(text)


def set_launch_options(path, appid, opts):
    def fn(app):
        app[:] = [kv for kv in app if kv[0] != "LaunchOptions"] + ([["LaunchOptions", opts.replace('"', '\\"')]] if opts else [])
    edit(path, ["UserLocalConfigStore", "Software", "Valve", "Steam", "apps", appid], fn)


def set_compat_tool(path, appid, tool):
    def fn(mapping):
        mapping[:] = [kv for kv in mapping if kv[0] != appid]
        if tool:
            mapping.append([appid, [["name", tool], ["config", ""], ["priority", "250"]]])
    edit(path, ["InstallConfigStore", "Software", "Valve", "Steam", "CompatToolMapping"], fn)


def selftest():
    import os
    import tempfile
    d = tempfile.mkdtemp()
    p = os.path.join(d, "localconfig.vdf")
    open(p, "w").write('"UserLocalConfigStore"\n{\n\t"Software"\n\t{\n\t\t"Valve"\n\t\t{\n\t\t\t"Steam"\n\t\t\t{\n\t\t\t\t"apps"\n\t\t\t\t{\n'
                       '\t\t\t\t\t"42"\n\t\t\t\t\t{\n\t\t\t\t\t\t"Playtime"\t\t"7"\n\t\t\t\t\t}\n\t\t\t\t}\n\t\t\t}\n\t\t}\n\t}\n}\n')
    set_launch_options(p, "42", "A=1 %command%")
    t = open(p).read()
    assert '"LaunchOptions"\t\t"A=1 %command%"' in t and '"Playtime"\t\t"7"' in t, t
    set_launch_options(p, "42", "")
    assert "LaunchOptions" not in open(p).read()
    c = os.path.join(d, "config.vdf")
    open(c, "w").write('"InstallConfigStore"\n{\n\t"Software"\n\t{\n\t\t"Valve"\n\t\t{\n\t\t\t"Steam"\n\t\t\t{\n\t\t\t\t"CompatToolMapping"\n\t\t\t\t{\n'
                       '\t\t\t\t\t"0"\n\t\t\t\t\t{\n\t\t\t\t\t\t"name"\t\t"proton_10"\n\t\t\t\t\t}\n\t\t\t\t}\n\t\t\t}\n\t\t}\n\t}\n}\n')
    set_compat_tool(c, "391220", "proton_experimental")
    t = open(c).read()
    assert '"391220"' in t and '"name"\t\t"proton_experimental"' in t and '"proton_10"' in t, t
    set_compat_tool(c, "391220", "")
    assert '"391220"' not in open(c).read()
    print("ok")


if __name__ == "__main__":
    if sys.argv[1] == "--selftest":
        selftest()
    elif sys.argv[1] == "launch-options":
        set_launch_options(*sys.argv[2:5])
        print(f"{sys.argv[3]} LaunchOptions = {sys.argv[4]!r}")
    elif sys.argv[1] == "compat-tool":
        set_compat_tool(*sys.argv[2:5])
        print(f"{sys.argv[3]} compatibility tool = {sys.argv[4]!r}")
    else:
        sys.exit(__doc__)
