"""Count "flash frames" in a screen recording: single frames that disagree with both neighbours while the neighbours
agree with each other (Galactic Racer with Nanite on: ground missing, hidden meshes drawn, no motion blur for one
frame; docs/FINDINGS.md). Camera cuts and real motion change a frame AND the next, so they mostly don't count.

  python3 -I tools/flashframes.py VIDEO [OUT_DIR]   prints JSON: frames, and how many frames have more than 1/10/20/40 %
                                                    of the lower half's 8x8 tiles flashing; OUT_DIR gets the worst
                                                    frames with their neighbours (a|b|c PNG strips) to look at
  python3 -I tools/flashframes.py --selftest

Decodes with ffmpeg to 480x270 grey. A tile flashes when its mean differs from both neighbours' by more than T while
the neighbours differ by less than T/2. The measure has a floor on intended effects (takedown camera cuts, the engines'
hologram): compare runs at the 10 and 20 % levels and look at the worst frames.
"""
import json
import os
import subprocess
import sys

import numpy as np

W, H, TILE, T = 480, 270, 8, 12.0


def frames(path):
    p = subprocess.Popen(["ffmpeg", "-loglevel", "error", "-i", path, "-vf", f"scale={W}:{H}", "-f", "rawvideo",
                          "-pix_fmt", "gray", "-"], stdout=subprocess.PIPE)
    n = W * H
    while True:
        buf = p.stdout.read(n)
        if len(buf) < n:
            break
        yield np.frombuffer(buf, np.uint8).reshape(H, W)
    p.wait()


def picture_box(fs):
    """(top, bottom, left, right) of the game's picture: x11grab can show a game that emulates a display mode (2560x1440
    on a 4K screen) in one corner with black around it, which would dilute every share."""
    lit = np.max(np.stack(fs[: 300: 5]), axis=0) > 16
    rows, cols = np.flatnonzero(lit.any(axis=1)), np.flatnonzero(lit.any(axis=0))
    return (rows[0], rows[-1] + 1, cols[0], cols[-1] + 1) if len(rows) and len(cols) else (0, H, 0, W)


def tiles(f, box=(0, H, 0, W)):
    """Mean of each 8x8 tile of the lower half of the picture (where the track is)."""
    t, b, l, r = box
    half = t + (b - t) // 2
    low = f[half: half + (b - half) // TILE * TILE, l: l + (r - l) // TILE * TILE].astype(np.float32)
    return low.reshape(low.shape[0] // TILE, TILE, -1, TILE).mean(axis=(1, 3))


def flash_share(a, b, c):
    """Share of tiles where b is the odd one out."""
    ab, cb, ac = np.abs(a - b), np.abs(c - b), np.abs(a - c)
    return float(((ab > T) & (cb > T) & (ac < T / 2)).mean())


def analyse(seq):
    """seq: tile arrays in order -> list of (index of b, share) for every inner frame."""
    out = []
    for i in range(1, len(seq) - 1):
        out.append((i, flash_share(seq[i - 1], seq[i], seq[i + 1])))
    return out


def summary(shares, n):
    return {"frames": n, **{f"over_{p}pct": sum(s > p / 100 for _, s in shares) for p in (1, 10, 20, 40)},
            "worst": [[i, round(s, 3)] for i, s in sorted(shares, key=lambda x: -x[1])[:5]]}


def dump(path, worst, out_dir):
    """The worst frames with their neighbours, side by side, at full resolution."""
    os.makedirs(out_dir, exist_ok=True)
    for i, _ in worst:
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", path, "-vf",
                        f"select='between(n,{i - 1},{i + 1})',scale=640:-2,tile=3x1", "-frames:v", "1",
                        os.path.join(out_dir, f"flash-{i:05d}.png")], check=False)


def main(argv):
    if argv[:1] == ["--selftest"]:
        rng = np.random.default_rng(1)
        base = rng.integers(0, 255, (H, W)).astype(np.uint8)
        moved = np.roll(base, 3, axis=1)                   # camera motion: changes b and c alike
        flash = base.copy()
        flash[H // 2:, :] = 0                              # ground gone for one frame
        seq = [tiles(x) for x in (base, base, flash, base, moved, moved)]
        res = dict(analyse(seq))
        assert res[2] > 0.9, res                           # the flash frame
        assert res[1] < 0.01 and res[3] < 0.01, res        # its neighbours are not flashes
        assert res[4] < 0.01, res                          # a cut that stays is not a flash
        s = summary(list(res.items()), 6)
        assert s["over_40pct"] == 1 and s["worst"][0][0] == 2, s
        corner = np.zeros((H, W), np.uint8)
        corner[: H * 2 // 3, : W * 2 // 3] = 200           # a game in the top-left two thirds, black around it
        assert picture_box([corner]) == (0, H * 2 // 3, 0, W * 2 // 3)
        print("ok")
        return
    path = argv[0]
    fs = list(frames(path))
    box = picture_box(fs) if fs else (0, H, 0, W)
    seq = [tiles(f, box) for f in fs]
    shares = analyse(seq)
    s = summary(shares, len(seq))
    if len(argv) > 1:
        dump(path, [w for w in s["worst"] if w[1] > 0.1], argv[1])
    s["picture"] = [int(x) for x in box]
    print(json.dumps(s))


if __name__ == "__main__":
    main(sys.argv[1:])
