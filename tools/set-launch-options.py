"""Set a Steam game's LaunchOptions in localconfig.vdf. Steam must be closed (it rewrites the file on exit).
Usage: python3 -I tools/set-launch-options.py LOCALCONFIG APPID "OPTIONS"   (empty OPTIONS clears them)
Prefer tools/steam-launch-options.sh, which closes and restarts Steam around this edit.
Self-check: python3 -I tools/set-launch-options.py --selftest"""
import re, shutil, sys, time

def parse(tokens, i=0):
    node = []
    while i < len(tokens):
        t = tokens[i]
        if t == "}": return node, i + 1
        key = t; i += 1
        if tokens[i] == "{": child, i = parse(tokens, i + 1); node.append([key, child])
        else: node.append([key, tokens[i]]); i += 1
    return node, i

def tokenize(text):
    return [m.group(1) if m.group(1) is not None else m.group(2)
            for m in re.finditer(r'"((?:[^"\\]|\\.)*)"|([{}])', text)]

def dump(node, depth=0):
    out = []
    for k, v in node:
        if isinstance(v, list): out += ["\t" * depth + f'"{k}"', "\t" * depth + "{", *dump(v, depth + 1), "\t" * depth + "}"]
        else: out.append("\t" * depth + f'"{k}"\t\t"{v}"')
    return out

def child(node, key):
    for kv in node:
        if kv[0].lower() == key.lower() and isinstance(kv[1], list): return kv[1]
    new = []; node.append([key, new]); return new

def set_options(path, appid, opts):
    tree, _ = parse(tokenize(open(path, encoding="utf-8").read()))
    app = tree
    for k in ["UserLocalConfigStore", "Software", "Valve", "Steam", "apps", appid]: app = child(app, k)
    app[:] = [kv for kv in app if kv[0] != "LaunchOptions"] + ([["LaunchOptions", opts.replace('"', '\\"')]] if opts else [])
    shutil.copy(path, f"{path}.bak-{int(time.time())}")
    open(path, "w", encoding="utf-8").write("\n".join(dump(tree)) + "\n")
    assert tokenize(open(path, encoding="utf-8").read()) == tokenize("\n".join(dump(tree)))  # round-trip check

def selftest():
    import os, tempfile
    d = tempfile.mkdtemp(); p = os.path.join(d, "localconfig.vdf")
    open(p, "w").write('"UserLocalConfigStore"\n{\n\t"Software"\n\t{\n\t\t"Valve"\n\t\t{\n\t\t\t"Steam"\n\t\t\t{\n\t\t\t\t"apps"\n\t\t\t\t{\n\t\t\t\t\t"42"\n\t\t\t\t\t{\n\t\t\t\t\t\t"Playtime"\t\t"7"\n\t\t\t\t\t}\n\t\t\t\t}\n\t\t\t}\n\t\t}\n\t}\n}\n')
    set_options(p, "42", "A=1 %command%"); t = open(p).read()
    assert '"LaunchOptions"\t\t"A=1 %command%"' in t and '"Playtime"\t\t"7"' in t, t
    set_options(p, "42", ""); assert "LaunchOptions" not in open(p).read()
    set_options(p, "99", "B=2 %command%"); assert '"99"' in open(p).read()
    print("ok")

if __name__ == "__main__":
    if sys.argv[1] == "--selftest": selftest(); sys.exit()
    path, appid, opts = sys.argv[1], sys.argv[2], sys.argv[3]
    set_options(path, appid, opts)
    print(f"{appid} LaunchOptions = {opts!r}")
