"""Attribute perf samples to stack layers for a FEX + Proton game run.

FEX labels translated code by guest library when FEX_LIBRARYJITNAMING=1 (perf-<pid>.map). perf does not apply
those maps to FEX's named JIT region ([anon:FEXMemJIT]), so this script resolves sample addresses itself.

Usage:     python3 -I analyze.py PERF_SCRIPT.txt [MAP_DIR] [GAME_COMM_REGEX]
           (PERF_SCRIPT.txt from: perf script -F comm,pid,tid,ip,sym,dso)
Self-check: python3 -I analyze.py --selftest
"""
import bisect
import collections
import glob
import json
import os
import re
import sys

LAYERS = [  # (layer, regex on resolved symbol or dso); first match wins
    ("kernel", r"\[kernel\.kallsyms\]"),
    ("FEX runtime (JIT compiler, dispatcher, syscalls)", r"/usr/bin/FEX\b|FEXInterpreter|libFEXCore|Dispatch_|FEXJIT"),
    ("NVIDIA x86 driver (emulated)", r"libnvidia-|libGLX_nvidia|libEGL_nvidia"),
    ("Vulkan loader (x86)", r"libvulkan\.so"),
    ("VKD3D-Proton (DX12->Vulkan)", r"d3d12(core)?\.dll|vkd3d"),
    ("DXVK (DX11->Vulkan)", r"d3d11\.dll|d3d10core\.dll|d3d9\.dll|dxgi\.dll|dxvk"),
    ("Steam overlay / client", r"gameoverlayrenderer|steamclient|steam_api|lsteamclient"),
    ("NVIDIA DLSS / Streamline (game-side)", r"nvngx|[/\\]sl\.\w+\.dll|nvapi"),
    ("Wine / Proton", r"/lib/wine/|ntdll|kernelbase|kernel32|ucrtbase|msvcr|msvcp|win32u|user32|winevulkan|combase|ole32|rpcrt4|advapi32|ws2_32|wine64-preloader"),
    ("x86 system libraries", r"x86_64-linux-gnu/|ld-linux-x86-64"),
    ("Game code", r"Cyberpunk2077\.exe|[/\\]bin[/\\]x64[/\\]|\.exe\b|\.dll\b"),
    ("Native arm64 libraries", r"aarch64-linux-gnu|/snap/steam/"),
    ("Translated, unlabeled (game .exe, inferred)", r"FEXMemJIT|\[unknown\]"),  # Wine maps the main exe without a file label
]
RX = [(name, re.compile(rx, re.I)) for name, rx in LAYERS]
LINE = re.compile(r"\s*(.+?)\s+(\d+)/(\d+)\s+([0-9a-f]+)\s+(.*?)\s*\((.*)\)\s*$")


def layer_of(sym, dso):
    for name, rx in RX:
        if rx.search(sym) or rx.search(dso):
            return name
    return "Other"


def load_maps(map_dir):
    """perf-<pid>.map files -> lookup(pid, ip) returning the label FEX gave that code, or None."""
    maps = {}
    for f in glob.glob(os.path.join(map_dir, "perf-*.map")):
        ents = []
        for ln in open(f, errors="replace"):
            parts = ln.rstrip("\n").split(" ", 2)
            if len(parts) == 3:
                start = int(parts[0], 16)
                ents.append((start, start + int(parts[1], 16), parts[2]))
        ents.sort()
        maps[int(os.path.basename(f)[5:-4])] = ([e[0] for e in ents], [e[1] for e in ents], [e[2] for e in ents])

    def lookup(pid, ip):
        m = maps.get(pid)
        if not m:
            return None
        i = bisect.bisect_right(m[0], ip) - 1
        return m[2][i] if i >= 0 and ip < m[1][i] else None
    return lookup


def parse(lines, lookup=None):
    """perf script -F comm,pid,tid,ip,sym,dso lines -> (comm, tid, symbol-or-label, dso)."""
    for ln in lines:
        m = LINE.match(ln)
        if not m:
            continue
        comm, pid, tid, ip, sym, dso = m.group(1).strip(), int(m.group(2)), int(m.group(3)), int(m.group(4), 16), m.group(5), m.group(6)
        if lookup and ("FEXMemJIT" in dso or "unknown" in sym):
            sym = lookup(pid, ip) or sym
        yield comm, tid, sym, dso


def summarize(rows, game_comm=r"redDispatcher|GameThread|RenderThread|Cyberpunk|wine|vkd3d|dxvk|Main|\.exe"):
    game = re.compile(game_comm, re.I)
    by_layer, by_thread, by_lib = collections.Counter(), collections.Counter(), collections.Counter()
    total = game_total = 0
    for comm, _tid, sym, dso in rows:
        total += 1
        if not game.search(comm):
            continue
        game_total += 1
        layer = layer_of(sym, dso)
        by_layer[layer] += 1
        by_thread[re.sub(r"\d+$", "N", comm)] += 1
        by_lib[re.split(r"[/\\]", sym)[-1][:60] if layer != "kernel" else "kernel:" + sym[:50]] += 1
    pct = lambda c, d: round(100 * c / d, 1) if d else 0.0
    return {
        "samples": total, "game_samples": game_total, "game_share_of_machine_pct": pct(game_total, total),
        "layers_pct_of_game": {k: pct(v, game_total) for k, v in by_layer.most_common()},
        "threads_pct_of_game": {k: pct(v, game_total) for k, v in by_thread.most_common(12)},
        "top_symbols_pct_of_game": {k: pct(v, game_total) for k, v in by_lib.most_common(25)},
    }


def selftest():
    rows = [("redDispatcher3", 1, "/c/Cyberpunk 2077/bin/x64/Cyberpunk2077.exe", "[anon:FEXMemJIT]"),
            ("GameThread", 2, "/p/files/lib/vkd3d/x86_64-windows/d3d12core.dll", "[anon:FEXMemJIT]"),
            ("GameThread", 2, "do_syscall", "[kernel.kallsyms]"), ("Xorg", 3, "y", "/usr/lib/xorg/Xorg"),
            ("RenderThread", 4, "/run/pressure-vessel/gfx/usr/lib/x86_64-linux-gnu/libnvidia-glcore.so.580", "[anon:FEXMemJIT]")]
    s = summarize(rows)
    assert s["game_samples"] == 4, s
    L = s["layers_pct_of_game"]
    assert L["Game code"] == L["VKD3D-Proton (DX12->Vulkan)"] == L["NVIDIA x86 driver (emulated)"] == L["kernel"] == 25.0, L
    # address resolution through a perf map
    import tempfile
    d = tempfile.mkdtemp()
    open(os.path.join(d, "perf-77.map"), "w").write("1000 100 /x/d3d12core.dll\n2000 10 /x/Cyberpunk2077.exe\n")
    look = load_maps(d)
    assert look(77, 0x1050).endswith("d3d12core.dll") and look(77, 0x2005).endswith(".exe") and look(77, 0x1500) is None
    line = "  redDispatcher3  77/80  2005 [unknown] ([anon:FEXMemJIT])"
    assert list(parse([line], look))[0][2].endswith("Cyberpunk2077.exe")
    print("ok")


if __name__ == "__main__":
    if sys.argv[1] == "--selftest":
        selftest()
        sys.exit()
    lookup = load_maps(sys.argv[2]) if len(sys.argv) > 2 else None
    rows = list(parse(open(sys.argv[1], errors="replace"), lookup))
    print(json.dumps(summarize(rows, *(sys.argv[3:4] or [])), indent=1))
