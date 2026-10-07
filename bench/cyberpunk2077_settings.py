"""Read or edit Cyberpunk 2077 UserSettings.json.
List:  python3 -I bench/cyberpunk2077_settings.py list [filter]
Set:   python3 -I bench/cyberpunk2077_settings.py set /graphics/presets/DLSS=Quality@1 ...
       (group_name/option=value; value parsed as JSON when possible; dynamic lists take value@index)
Known working values on GB10 (confirmed by the benchmark summary): QuickPresets=High@4, ResolutionScaling=Off@0 | DLSS@1,
DLSS=Quality@1, FrameGeneration=Off@0 | DLSS@1 (+ DLSSFrameGen=true, DLSS_MultiFrameGeneration=x2)."""
import json, os, shutil, sys
U = os.path.join(os.environ.get("STEAM_ROOT", os.path.expanduser("~/snap/steam/common/.local/share/Steam")),
                 "steamapps/compatdata/1091500/pfx/drive_c/users/steamuser/AppData/Local/CD Projekt Red/Cyberpunk 2077/UserSettings.json")
d = json.load(open(U))
groups = {g["group_name"]: g for g in d["data"]}
if sys.argv[1] == "list":
    f = sys.argv[2].lower() if len(sys.argv) > 2 else ""
    for name, g in groups.items():
        for o in g["options"]:
            line = f'{name}/{o["name"]} = {o.get("value")!r}  [{o.get("type")}] {o.get("values", "")}'
            if f in line.lower(): print(line[:230])
elif sys.argv[1] == "set":
    shutil.copy(U, U + ".bak")
    for arg in sys.argv[2:]:
        path, val = arg.split("=", 1)
        gname, oname = path.rsplit("/", 1)
        try: val = json.loads(val)
        except json.JSONDecodeError: pass
        opt = next(o for o in groups[gname]["options"] if o["name"] == oname)  # StopIteration = unknown key
        if "values" in opt and "@" not in str(val): assert val in opt["values"], f"{arg}: allowed {opt['values']}"
        idx = None
        if isinstance(val, str) and "@" in val: val, idx = val.rsplit("@", 1); idx = int(idx)  # dynamic lists: value@index
        opt["value"] = val
        if idx is not None: opt["index"] = idx
        print(f"{path} -> {val!r}" + (f" (index {idx})" if idx is not None else ""))
    json.dump(d, open(U, "w"), indent=2)
