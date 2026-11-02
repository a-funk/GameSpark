"""Read or edit Cyberpunk 2077's UserSettings.json (the Proton prefix of app 1091500).

List:      python3 -I bench/cyberpunk2077_settings.py list [filter]
Show:      python3 -I bench/cyberpunk2077_settings.py show        the options that decide the cost at 4K
Describe:  python3 -I bench/cyberpunk2077_settings.py describe    one line for a run record (resolution, upscaler, ...)
Set:       python3 -I bench/cyberpunk2077_settings.py set /graphics/presets/DLSS='Performance@4' /video/display/Resolution=3840x2160@9 ...
           (group/option=value; the value is parsed as JSON when it can be: 16, true, 0.5. A list option takes one of its
           names; a DYNAMIC list (is_dynamic: resolutions, window modes, upscaler modes) takes value@index, the index the
           game writes for that value; a static list gets its index from its values.)
Self-check: python3 -I bench/cyberpunk2077_settings.py --selftest
File:      $CP_USERSETTINGS, else the prefix's UserSettings.json under $STEAM_ROOT (default ~/snap/steam/common/.local/share/Steam).

Nothing is written unless every option exists and every value suits it. Only the changed values differ in the file (it is
written the way the game writes it: 4-space indent, no trailing newline). Back the file up first (profiles/settings/lib.sh
sg_backup; profiles/settings/1091500/apply.sh and bench/games/cyberpunk2077.sh do): this tool keeps no copy of its own.
The game must be closed: it rewrites the file.

Known working values on GB10 (confirmed by the benchmark summary): QuickPresets=High@4, ResolutionScaling=Off@0 | DLSS@1,
DLSS=Quality@2, FrameGeneration=Off@0 | DLSS@1 (+ DLSSFrameGen=true, DLSS_MultiFrameGeneration=x2). The game's own
names for the DLSS modes (renderInGameSettings.cpp in Cyberpunk2077.exe): Auto, Quality, Balanced, Performance and
"Ultra Performance" (with the space). The index of the dynamic lists is the game's own order: not read back by this tool.
"""
import json
import os
import sys
import tempfile

DEFAULT = "~/snap/steam/common/.local/share/Steam"
REL = "steamapps/compatdata/1091500/pfx/drive_c/users/steamuser/AppData/Local/CD Projekt Red/Cyberpunk 2077/UserSettings.json"

# What `show` prints: the options that decide the cost and the look at 4K.
SHOW = """/video/display/Resolution /video/display/WindowMode /video/display/VSync /video/display/MaximumFPS_OnOff
/video/display/MaximumFPS_Value /video/display/ReflexMode
/graphics/presets/QuickPresets /graphics/presets/ResolutionScaling /graphics/presets/DLSS_BackendPreset
/graphics/presets/DLSS /graphics/presets/DLSS_D /graphics/presets/FrameGeneration /graphics/presets/DLSSFrameGen
/graphics/presets/DynamicResolutionScaling /graphics/presets/TextureQuality /graphics/raytracing/RayTracing
/graphics/raytracing/RayTracedPathTracing /graphics/advanced/ContactShadows /graphics/advanced/Anisotropy
/graphics/advanced/ShadowMeshQuality /graphics/advanced/LocalShadowsQuality /graphics/advanced/CascadedShadowsRange
/graphics/advanced/CascadedShadowsResolution /graphics/advanced/DistantShadowsResolution
/graphics/advanced/VolumetricFogResolution /graphics/advanced/VolumetricCloudsQuality /graphics/advanced/MaxDynamicDecals
/graphics/advanced/ScreenSpaceReflectionsQuality /graphics/advanced/SubsurfaceScatteringQuality
/graphics/advanced/AmbientOcclusion /graphics/advanced/ColorPrecision /graphics/advanced/MirrorQuality
/graphics/advanced/LODPreset /graphics/performance/CrowdDensity /gameplay/performance/CrowdDensity""".split()

# DLSS render scale (width and height) per mode name, for `describe`.
SCALE = {"Quality": 2 / 3, "Balanced": 0.58, "Performance": 0.5, "Ultra Performance": 1 / 3, "DLAA": 1.0}


def path():
    root = os.environ.get("STEAM_ROOT") or os.path.expanduser(DEFAULT)
    return os.environ.get("CP_USERSETTINGS") or os.path.join(root, REL)


def load(p):
    text = open(p, encoding="utf-8").read()
    return text, json.loads(text)


def dump(doc):
    return json.dumps(doc, indent=4)   # byte for byte what the game wrote (checked in --selftest and on the real file)


def options(doc):
    return {g["group_name"] + "/" + o["name"]: o for g in doc["data"] for o in g["options"]}


def parse(arg, opts):
    """'group/option=value[@index]' -> (key, option, value, index or None); raises ValueError with the reason."""
    if "=" not in arg:
        raise ValueError(f"{arg}: expected group/option=value")
    key, val = arg.split("=", 1)
    opt = opts.get(key)
    if opt is None:
        raise ValueError(f"{key}: no such option (list shows them)")
    try:
        val = json.loads(val)
    except json.JSONDecodeError:
        pass
    idx = None
    if isinstance(val, str) and "@" in val:
        val, _, i = val.rpartition("@")
        try:
            idx = int(i)
        except ValueError:
            raise ValueError(f"{key}: index after @ must be a number, got {i!r}")
    t = opt.get("type")
    if t == "bool":
        if not isinstance(val, bool):
            raise ValueError(f"{key}: a bool, true or false (got {val!r})")
    elif t in ("float", "int"):
        if isinstance(val, bool) or not isinstance(val, (int, float)) or (t == "int" and not isinstance(val, int)):
            raise ValueError(f"{key}: a number ({t}), got {val!r}")
        lo, hi = opt.get("min_value"), opt.get("max_value")
        if (lo is not None and val < lo) or (hi is not None and val > hi):
            raise ValueError(f"{key}: {val} outside {lo}..{hi}")
        if t == "float":
            val = float(val)
    elif "values" in opt:
        if val not in opt["values"]:
            raise ValueError(f"{key}: {val!r} is not one of {opt['values']}")
        idx = opt["values"].index(val)
    elif opt.get("is_dynamic"):
        if not isinstance(val, (str, int)) or isinstance(val, bool):
            raise ValueError(f"{key}: a name (dynamic list), got {val!r}")
    else:
        raise ValueError(f"{key}: unsupported option type {t!r}")
    return key, opt, val, idx


def apply(doc, args):
    opts = options(doc)
    changes, notes = [], []
    for a in args:
        key, opt, val, idx = parse(a, opts)
        if opt.get("is_dynamic") and idx is None and "index" in opt:
            notes.append(f"note: {key} is a dynamic list: its index stays {opt['index']} (give value@index to set it)")
        opt["value"] = val
        if idx is not None:
            opt["index"] = idx
        changes.append(f"{key} -> {val!r}" + (f" (index {idx})" if idx is not None else ""))
    return changes, notes


def write(p, text):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p) or ".", prefix=".UserSettings.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.chmod(tmp, os.stat(p).st_mode & 0o7777)
        os.replace(tmp, p)
    except BaseException:
        os.path.exists(tmp) and os.unlink(tmp)
        raise


def describe(doc):
    o = options(doc)
    v = lambda k: o[k].get("value") if k in o else None
    res = str(v("/video/display/Resolution") or "?")
    scaling, mode = v("/graphics/presets/ResolutionScaling"), v("/graphics/presets/DLSS")
    if scaling == "DLSS":
        try:
            w, h = (int(x) for x in res.split("x"))
            f = SCALE.get(mode)
            render = f" render {round(w * f)}x{round(h * f)}" if f else ""
        except ValueError:
            render = ""
        up = f"DLSS {mode} ({v('/graphics/presets/DLSS_BackendPreset')}{render})"
    else:
        up = f"{scaling}" + (f" {mode}" if scaling not in (None, "Off") else "")
    fg = v("/graphics/presets/FrameGeneration")
    fg = "" if fg == "Off" else f" · frame gen {fg}"
    rt = "RT on" if v("/graphics/raytracing/RayTracing") else "RT off"
    adv = "/graphics/advanced/"
    return (f"{res} · {up}{fg} · {rt} · SSR {v(adv + 'ScreenSpaceReflectionsQuality')}, fog {v(adv + 'VolumetricFogResolution')}, "
            f"clouds {v(adv + 'VolumetricCloudsQuality')}, shadows {v(adv + 'CascadedShadowsResolution')}, "
            f"crowd {v('/graphics/performance/CrowdDensity')}")


def selftest():
    tmp = tempfile.mkdtemp()
    doc = {"version": 140, "data": [
        {"group_name": "/video/display", "options": [
            {"name": "Resolution", "type": "string_list", "is_dynamic": True, "value": "1920x1080", "index": 8},
            {"name": "VSync", "type": "string_list", "is_dynamic": True, "value": "UI-Settings-Video-QualitySetting-Off", "index": 0},
            {"name": "MaximumFPS_OnOff", "type": "bool", "value": False, "default_value": False},
            {"name": "MaximumFPS_Value", "type": "int", "value": 30, "min_value": 10, "max_value": 240}]},
        {"group_name": "/graphics/presets", "options": [
            {"name": "ResolutionScaling", "type": "string_list", "is_dynamic": True, "value": "DLSS", "index": 1},
            {"name": "DLSS", "type": "string_list", "is_dynamic": True, "value": "Quality", "index": 2},
            {"name": "DLSS_BackendPreset", "type": "string_list", "is_dynamic": False, "value": "Transformer", "index": 0,
             "values": ["Transformer", "Legacy"]},
            {"name": "DLSS_NewSharpness", "type": "float", "value": 0.0, "min_value": 0.0, "max_value": 1.0}]},
        {"group_name": "/graphics/advanced", "options": [
            {"name": "Anisotropy", "type": "int_list", "index": 0, "value": 1, "values": [1, 4, 8, 16]},
            {"name": "VolumetricFogResolution", "type": "string_list", "value": "Ultra", "index": 3,
             "values": ["Low", "Medium", "High", "Ultra"]}]}]}
    p = os.path.join(tmp, "UserSettings.json")
    text = dump(doc)
    open(p, "w").write(text)
    assert load(p)[0] == dump(load(p)[1]), "the writer is not byte-compatible with the game's file"
    _, d = load(p)
    ch, notes = apply(d, ["/video/display/Resolution=3840x2160@9", "/graphics/presets/DLSS=Ultra Performance@5",
                          "/graphics/advanced/Anisotropy=16", "/graphics/advanced/VolumetricFogResolution=Medium",
                          "/video/display/MaximumFPS_OnOff=true", "/video/display/MaximumFPS_Value=60",
                          "/graphics/presets/DLSS_NewSharpness=0.5", "/graphics/presets/DLSS_BackendPreset=Legacy"])
    o = options(d)
    assert o["/video/display/Resolution"]["value"] == "3840x2160" and o["/video/display/Resolution"]["index"] == 9
    assert o["/graphics/presets/DLSS"]["value"] == "Ultra Performance" and o["/graphics/presets/DLSS"]["index"] == 5
    assert o["/graphics/advanced/Anisotropy"]["value"] == 16 and o["/graphics/advanced/Anisotropy"]["index"] == 3
    assert o["/graphics/advanced/VolumetricFogResolution"]["index"] == 1 and o["/graphics/presets/DLSS_BackendPreset"]["index"] == 1
    assert o["/video/display/MaximumFPS_OnOff"]["value"] is True and o["/video/display/MaximumFPS_Value"]["value"] == 60
    assert not notes and len(ch) == 8, (ch, notes)
    write(p, dump(d))
    _, d2 = load(p)
    assert options(d2)["/graphics/presets/DLSS"]["value"] == "Ultra Performance"
    ch, notes = apply(d2, ["/graphics/presets/DLSS=Quality"])   # dynamic list without an index: the index stays, with a note
    assert len(notes) == 1 and options(d2)["/graphics/presets/DLSS"]["index"] == 5, notes
    for bad in ("/video/display/Nope=1", "/video/display/MaximumFPS_OnOff=1", "/video/display/MaximumFPS_Value=999",
                "/graphics/advanced/VolumetricFogResolution=Insane", "/graphics/advanced/Anisotropy=2",
                "/video/display/Resolution=3840x2160@x", "no-equals"):
        try:
            apply(d2, [bad])
        except ValueError:
            continue
        raise AssertionError("accepted " + bad)
    line = describe(d2)
    assert line.startswith("3840x2160 · DLSS Quality (Legacy render 2560x1440)"), line
    print("ok")


def main(argv):
    cmd = argv[0] if argv else "help"
    if cmd == "--selftest":
        return selftest()
    if cmd not in ("list", "show", "describe", "set"):
        sys.exit(__doc__)
    p = path()
    try:
        text, doc = load(p)
    except (OSError, ValueError) as e:
        sys.exit(f"error: cannot read {p}: {e}")
    if cmd == "list":
        f = argv[1].lower() if len(argv) > 1 else ""
        for g in doc["data"]:
            for o in g["options"]:
                line = f'{g["group_name"]}/{o["name"]} = {o.get("value")!r}  [{o.get("type")}] {o.get("values", "")}'
                if f in line.lower():
                    print(line[:230])
    elif cmd == "show":
        o = options(doc)
        for k in SHOW:
            if k in o:
                x = o[k]
                print(f"{k} = {x.get('value')!r}" + (f"  (index {x['index']})" if "index" in x else ""))
    elif cmd == "describe":
        print(describe(doc))
    else:
        try:
            changes, notes = apply(doc, argv[1:])
        except ValueError as e:
            sys.exit(f"error: {e}; nothing written")
        out = dump(doc)
        if out != text:
            write(p, out)
        for line in changes + notes:
            print(line)


if __name__ == "__main__":
    main(sys.argv[1:])
