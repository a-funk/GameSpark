#!/usr/bin/env python3
"""Record a DualSense's raw input while a player races, and play it back through a virtual DualSense, so benchmark
runs drive the way the player did. Stdlib only. The game reads the pad as raw HID (Proton's hidraw path), so the
replay feeds the very bytes the pad sent, through a kernel HID device (uhid) built from the pad's own report
descriptor and feature reports (calibration, firmware), with another MAC so it never collides with the real pad.
Replays follow the game, not just the clock: they start when the race intro starts and re-align on every letterbox
edge (set pieces, the finish), seen live in a small screen strip.

  padreplay.py record HIDRAW OUT [SECONDS]   the pad's reports with both clocks -> OUT (the player plays meanwhile)
  padreplay.py info REC                      reports, duration, clock span
  padreplay.py edges VIDEO                   letterbox edges of a strip capture with CLOCK_REALTIME timestamps (JSON)
  padreplay.py watch OUT SECONDS [WxH+X+Y [VIDEO]]
                                             the same, live from the screen (strip default 440x200+780+100 at 4K):
                                             one "ns start|end" line per edge, appended to OUT; VIDEO keeps the strip
  padreplay.py cut REC OUT FROM_NS TO_NS EDGES.json [KEY=VALUE...]
                                             one race: the reports and edges between FROM and TO, plus notes
  padreplay.py races REC EDGES.json LOADS OUTDIR MENU_RE
                                             one race file per map load in LOADS ("ns map" lines) whose map does not
                                             match MENU_RE: from the intro's letterbox to the finish's
  padreplay.py note RACE KEY=VALUE...        set notes on a race (the bench reads how to reach its event there)
  padreplay.py twin RACE EDGES SECONDS [--summary F.json] [--log F] [--idle 1]
                                             the virtual DualSense: at rest until EDGES (a watch file) shows the race
                                             intro starting, then RACE's input, re-aligned on each later edge, then at
                                             rest until SECONDS, SIGTERM or a "0 stop" line in EDGES. Needs /dev/uhid
                                             (root). --summary: each recorded edge's live time and the corrections;
                                             --idle 1: follow the edges but send only a pad at rest (the game's AI
                                             drives)
  padreplay.py --selftest

REC format: one JSON line (device, uevent, rdesc hex, features {"0x5": hex, ...}, start clocks; races add "race":
{from_ns, to_ns, edges [[ns, kind]...], notes}), then records of <QQH (CLOCK_MONOTONIC ns, CLOCK_REALTIME ns, length)
followed by the report bytes.
"""
import fcntl, glob, json, os, select, signal, struct, subprocess, sys, time, zlib

# ---------------------------------------------------------------------------------------------------- DualSense (BT)
REPORT_BT = 0x31          # full input report over Bluetooth: 78 bytes, CRC-32 in the last 4
SEED_INPUT, SEED_FEATURE = 0xA1, 0xA3   # the CRC covers a seed byte then the report (zlib CRC-32)
PAIRING = 0x09            # feature report: bytes 1-6 hold the MAC, low byte first


def ds_crc(seed, data):
    return zlib.crc32(data, zlib.crc32(bytes([seed]))) & 0xFFFFFFFF


def with_crc(seed, report):
    """report with its last 4 bytes replaced by the CRC of everything before them"""
    return report[:-4] + struct.pack("<I", ds_crc(seed, report[:-4]))


def crc_ok(seed, report):
    return len(report) > 4 and struct.unpack("<I", report[-4:])[0] == ds_crc(seed, report[:-4])


def twin_pairing(report):
    """The pairing report with the MAC's locally administered bit set (14:3a:.. -> 16:3a:..): never a real pad's
    address, so the kernel's duplicate check passes even with the player's pad on. -> (report, the MAC as the kernel
    prints it, which it also makes the device's uniq)"""
    r = bytearray(report)
    r[6] ^= 0x02
    return with_crc(SEED_FEATURE, bytes(r)), ":".join(f"{b:02x}" for b in reversed(r[1:7]))


def neutral(report):
    """An input report with nothing pressed: sticks centred, triggers released, D-pad neutral, no touch."""
    r = bytearray(report)
    if r[0] != REPORT_BT or len(r) != 78:
        raise ValueError("expects a Bluetooth 0x31 report")
    b = 2                                   # the common report starts after id and tag
    r[b:b + 4] = b"\x80\x80\x80\x80"        # left x/y, right x/y
    r[b + 4:b + 6] = b"\x00\x00"            # L2, R2
    r[b + 7] = 0x08                         # buttons[0]: D-pad neutral (hat 8), no face buttons
    r[b + 8] = r[b + 9] = 0x00              # buttons[1], buttons[2]
    r[b + 32] |= 0x80                       # touch point 1: bit 7 set = not touching
    r[b + 36] |= 0x80                       # touch point 2
    return with_crc(SEED_INPUT, bytes(r))


def for_replay(report):
    """The report as the twin sends it: without the PS button (it opens Steam's overlay), and with a full battery (the
    recording's 5% raised the desktop's low-battery banner)."""
    r = bytearray(report)
    r[11] &= ~0x01                          # buttons[2] bit 0: PS
    r[54] = 0x2A                            # status: high nibble 2 = full
    return with_crc(SEED_INPUT, bytes(r))


# ---------------------------------------------------------------------------------------------------- recording file
HDR_REC = struct.Struct("<QQH")


def read_rec(path):
    with open(path, "rb") as f:
        head = json.loads(f.readline())
        data = f.read()
    recs, i = [], 0
    while i + HDR_REC.size <= len(data):
        mono, real, n = HDR_REC.unpack_from(data, i)
        i += HDR_REC.size
        if i + n > len(data):
            break                           # a record cut short when the recorder was stopped
        recs.append((mono, real, data[i:i + n]))
        i += n
    return head, recs


def record(dev, out, seconds):
    if "/virtual/misc/uhid/" in os.path.realpath(f"/sys/class/hidraw/{os.path.basename(dev)}/device"):
        raise SystemExit(f"{dev} is a virtual pad (a replay's twin), not the player's")
    fd = os.open(dev, os.O_RDWR)

    def feature(rid, size=64):
        buf = bytearray(size)
        buf[0] = rid
        n = fcntl.ioctl(fd, (3 << 30) | (size << 16) | (ord("H") << 8) | 0x07, buf, True)  # HIDIOCGFEATURE(size)
        return bytes(buf[:n]).hex()
    sysdir = f"/sys/class/hidraw/{os.path.basename(dev)}/device/"
    head = {"device": dev, "uevent": open(sysdir + "uevent").read(),
            "rdesc": open(sysdir + "report_descriptor", "rb").read().hex(),
            "features": {hex(r): feature(r) for r in (0x05, PAIRING, 0x20)},
            "start_monotonic_ns": time.monotonic_ns(), "start_realtime_ns": time.time_ns()}
    n, end = 0, time.monotonic() + seconds

    def interrupt(*_):          # also for SIGINT: a background job of a script starts with SIGINT ignored
        raise KeyboardInterrupt
    for s in (signal.SIGINT, signal.SIGTERM):
        signal.signal(s, interrupt)
    with open(out, "wb") as f:
        f.write(json.dumps(head).encode() + b"\n")
        try:
            while time.monotonic() < end:
                r = os.read(fd, 128)
                f.write(HDR_REC.pack(time.monotonic_ns(), time.time_ns(), len(r)) + r)
                n += 1
                if n % 2500 == 0:
                    f.flush()
        except (OSError, KeyboardInterrupt) as e:   # the pad went away, or Ctrl-C
            print("stopped:", e, file=sys.stderr)
    print(f"{n} reports -> {out}")


# ---------------------------------------------------------------------------------------------------- uhid
# include/uapi/linux/uhid.h: struct uhid_event is packed, {u32 type; union {...}}; the largest member is create2
UHID_DESTROY, UHID_START, UHID_STOP, UHID_OPEN, UHID_CLOSE, UHID_OUTPUT = 1, 2, 3, 4, 5, 6
UHID_GET_REPORT, UHID_GET_REPORT_REPLY, UHID_CREATE2, UHID_INPUT2 = 9, 10, 11, 12
UHID_SET_REPORT, UHID_SET_REPORT_REPLY = 13, 14
DATA_MAX = 4096
CREATE2 = struct.Struct(f"<I128s64s64sHHIIII{DATA_MAX}s")    # 4376: any write of 4 bytes or more is accepted
EVENT_SIZE = 4380         # sizeof(struct uhid_event) on arm64 and x86-64 (uhid_start_req's u64 pads the union)
BUS_BLUETOOTH, EIO = 0x05, 5


def uhid_create(fd, name, phys, uniq, rdesc, vendor=0x054C, product=0x0CE6, version=0x0100):
    os.write(fd, CREATE2.pack(UHID_CREATE2, name.encode(), phys.encode(), uniq.encode(), len(rdesc), BUS_BLUETOOTH,
                              vendor, product, version, 0, rdesc))


def uhid_input(fd, report):
    os.write(fd, struct.pack(f"<IH{len(report)}s", UHID_INPUT2, len(report), report))


def uhid_get_report_reply(fd, req_id, data, err=0):
    os.write(fd, struct.pack(f"<IIHH{len(data)}s", UHID_GET_REPORT_REPLY, req_id, err, len(data), data))


def uhid_set_report_reply(fd, req_id, err=0):
    os.write(fd, struct.pack("<IIH", UHID_SET_REPORT_REPLY, req_id, err))


def handle_event(fd, buf, features, log):
    """One event from the kernel: answer feature requests from the recorded reports, ack writes, drop output."""
    etype = struct.unpack_from("<I", buf)[0]
    if etype == UHID_GET_REPORT:
        req_id, rnum, rtype = struct.unpack_from("<IBB", buf, 4)
        data = features.get(rnum) if rtype == 0 else None      # 0: UHID_FEATURE_REPORT
        uhid_get_report_reply(fd, req_id, data or b"", 0 if data else EIO)
        log(f"get report 0x{rnum:02x} -> {'%d bytes' % len(data) if data else 'EIO'}")
    elif etype == UHID_SET_REPORT:
        req_id, rnum = struct.unpack_from("<IB", buf, 4)
        uhid_set_report_reply(fd, req_id)
        log(f"set report 0x{rnum:02x} acknowledged")
    elif etype in (UHID_START, UHID_STOP, UHID_OPEN, UHID_CLOSE):   # STOP before the driver bound = probe failed
        log({UHID_START: "started", UHID_STOP: "stopped", UHID_OPEN: "opened", UHID_CLOSE: "closed"}[etype])
    return etype


# ---------------------------------------------------------------------------------------------------- race anchors
# Galactic Racer letterboxes (2.39:1, black bars 277 px tall at 4K) its race intro, the set pieces in a race and the
# finish. Their edges are the anchors: the replay starts on the intro's first frame and re-aligns on each later edge,
# so drift from a slightly different line through a corner does not add up over a race. The strip is the screen region
# x 780-1220, y 100-300 at 4K (it straddles the bar's lower edge and holds the race clock), scaled to GW x GH.
GW, GH = 44, 20
STRIP = "440x200+780+100"


class Letterbox:
    """Letterbox on/off from a GW x GH gray strip: the bar rows black, the rows below its edge not. A new state must hold
    HOLD frames; its edge carries the time of its first frame."""
    HOLD = 3

    def __init__(self):
        self.state, self.cand = False, None

    @staticmethod
    def on(fr):
        return max(fr[:16 * GW]) < 12 and sum(fr[18 * GW:]) / (2 * GW) > 20

    def feed(self, t, fr):
        s = self.on(fr)
        if s == self.state:
            self.cand = None
        elif self.cand is None:
            self.cand = [t, 1]
        else:
            self.cand[1] += 1
            if self.cand[1] >= self.HOLD:
                self.state, t0, self.cand = s, self.cand[0], None
                return t0, "start" if s else "end"
        return None


def die_with_parent():
    """for the capture child: Linux kills it when its parent goes (PR_SET_PDEATHSIG), even on SIGKILL"""
    if sys.platform == "linux":
        import ctypes
        ctypes.CDLL(None).prctl(1, signal.SIGKILL)


def frames(cmd):
    """GW x GH gray frames from an ffmpeg command writing rawvideo to stdout"""
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, preexec_fn=die_with_parent)
    try:
        while True:
            fr = p.stdout.read(GW * GH)
            if len(fr) < GW * GH:
                return
            yield fr
    finally:
        p.terminate()                       # ffmpeg closes its outputs (the strip video) on SIGTERM
        try:
            p.wait(5)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()


def scale_args():
    return ["-vf", f"scale={GW}:{GH},format=gray", "-f", "rawvideo", "-flush_packets", "1", "-"]


def edges_of_video(video):
    """Letterbox edges of a strip capture whose timestamps are CLOCK_REALTIME (ffmpeg -use_wallclock_as_timestamps 1
    -copyts) -> [(ns, kind)]"""
    pts = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "packet=pts_time", "-of",
                          "csv=p=0", video], capture_output=True, text=True, check=True).stdout.split()
    det, out = Letterbox(), []
    for t, fr in zip(pts, frames(["ffmpeg", "-nostdin", "-v", "error", "-i", video] + scale_args())):
        e = det.feed(round(float(t) * 1e9), fr)
        if e:
            out.append(e)
    return out


def watch(out, seconds, region=STRIP, video=None):
    """Live: letterbox edges of the screen strip, one "ns kind" line each, appended to out as they happen; video also
    keeps the strip (CLOCK_REALTIME timestamps) for reading the race clock afterwards."""
    size, x, y = region.split("+")
    cmd = ["ffmpeg", "-nostdin", "-loglevel", "error", "-use_wallclock_as_timestamps", "1", "-f", "x11grab",
           "-framerate", "30", "-video_size", size, "-i", f"{os.environ.get('DISPLAY', ':0')}+{x},{y}"]
    if video:
        cmd += ["-filter_complex", f"[0:v]split=2[a][b];[a]scale={GW}:{GH},format=gray[g]", "-map", "[b]", "-c:v",
                "libx264", "-preset", "ultrafast", "-crf", "10", "-copyts", video, "-map", "[g]"] + scale_args()[2:]
    else:
        cmd += scale_args()
    det, end = Letterbox(), time.monotonic() + seconds
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))   # so the capture is stopped (and its video closed)
    with open(out, "a") as f:
        for fr in frames(cmd):
            e = det.feed(time.time_ns(), fr)
            if e:
                f.write(f"{e[0]} {e[1]}\n")
                f.flush()
            if time.monotonic() > end:
                break


def cut(rec, out, t_from, t_to, edges, notes):
    """One race from a recording: the reports between t_from and t_to (CLOCK_REALTIME ns) and the letterbox edges
    between them, which the twin anchors on."""
    head, recs = read_rec(rec)
    head["race"] = dict(notes, from_ns=t_from, to_ns=t_to, edges=[list(e) for e in edges if t_from <= e[0] <= t_to])
    with open(out, "wb") as f:
        f.write(json.dumps(head).encode() + b"\n")
        for mono, real, r in recs:
            if t_from <= real <= t_to:
                f.write(HDR_REC.pack(mono, real, len(r)) + r)
    return head["race"]


def races(rec, edges, loads, outdir, menu_re):
    """One race per map load of a recording session: from 1 s before the first letterbox start after the load (the
    intro) to 1 s after the last one before the next load (the finish cinematic). loads: [(ns, map)], menus included
    (they bound the race before them). -> [(file, race notes)]"""
    import re
    reals = [real for _, real, _ in read_rec(rec)[1]]
    out = []
    for (t, m), (t2, _) in zip(loads, loads[1:] + [(edges[-1][0] + 1, None)] if edges else []):
        starts = [e[0] for e in edges if t <= e[0] < t2 and e[1] == "start"]
        if re.fullmatch(menu_re, m) or len(starts) < 2:
            continue
        a, b = starts[0] - 1_000_000_000, starts[-1] + 1_000_000_000
        if not reals or a < reals[0] or b > reals[-1]:
            continue                                    # the pad was not recorded through the whole race
        name = f"{m.removeprefix('L_').lower().replace('_', '-')}-{time.strftime('%m%d-%H%M', time.localtime(t / 1e9))}"
        path = os.path.join(outdir, name + ".rec")
        out.append((path, cut(rec, path, a, b, edges, {"map": m, "loaded_ns": t, "seconds": round((b - a) / 1e9, 1)})))
    return out


def note(race, notes):
    """set KEY=VALUE notes on a race (e.g. how the bench reaches its event)"""
    with open(race, "rb") as f:
        head = json.loads(f.readline())
        rest = f.read()
    head["race"].update(notes)
    with open(race + ".new", "wb") as f:
        f.write(json.dumps(head).encode() + b"\n" + rest)
    os.replace(race + ".new", race)
    return {k: v for k, v in head["race"].items() if k != "edges"}


class Replay:
    """Which recorded report is due now. Anchored when the first live edge of the race's first recorded kind arrives
    (the intro starting); each later live edge that has a recorded edge of the same kind within WINDOW of where the
    replay expects it moves the anchor onto that edge. Later in the recording: the reports in between are skipped;
    earlier: the current input is held until the recording catches up (a press is never sent twice)."""
    WINDOW = 2_500_000_000

    def __init__(self, reports, edges):
        self.reports, self.edges = reports, [tuple(e) for e in edges]       # [(ns, bytes)], [(ns, kind)]
        self.delta, self.j, self.i = None, -1, 0        # live - recorded time; last matched edge; next report
        self.live, self.corr = {}, []                   # recorded edge index -> live ns; corrections (ns)

    def edge(self, t, kind):
        if self.delta is None:
            if not self.edges or kind != self.edges[0][1]:
                return f"{kind} edge before the race ignored"
            self.delta, self.j, self.live[0] = t - self.edges[0][0], 0, t
            while self.i + 1 < len(self.reports) and self.reports[self.i + 1][0] <= self.edges[0][0]:
                self.i += 1                             # start from the input held at the anchor
            return f"anchored: {kind} edge = recorded edge 0"
        pred = t - self.delta
        near = [k for k in range(self.j + 1, len(self.edges))
                if self.edges[k][1] == kind and abs(self.edges[k][0] - pred) < self.WINDOW]
        if not near:
            return f"{kind} edge at {(pred - self.edges[0][0]) / 1e9:.2f} s unmatched"
        k = min(near, key=lambda k: abs(self.edges[k][0] - pred))
        corr = t - self.edges[k][0] - self.delta
        self.delta, self.j, self.live[k] = self.delta + corr, k, t
        self.corr.append(corr)
        return f"{kind} edge = recorded edge {k} at {(self.edges[k][0] - self.edges[0][0]) / 1e9:.2f} s: {corr / 1e6:+.0f} ms"

    def due(self, now):
        """the newest report due at live time now and not sent yet, else None"""
        if self.delta is None or self.i >= len(self.reports) or self.reports[self.i][0] > now - self.delta:
            return None
        while self.i + 1 < len(self.reports) and self.reports[self.i + 1][0] <= now - self.delta:
            self.i += 1
        self.i += 1
        return self.reports[self.i - 1][1]

    def done(self):
        return self.delta is not None and self.i >= len(self.reports)

    def summary(self):
        """each recorded edge with its live time: as seen, or where the replay put it when it was not seen"""
        return {"corrections_ms": [round(c / 1e6) for c in self.corr], "edges": [
            {"kind": k, "recorded_s": round((t - self.edges[0][0]) / 1e9, 3), "matched": i in self.live,
             "live_ns": self.live.get(i, None if self.delta is None else t + self.delta)} for i, (t, k) in enumerate(self.edges)]}


def playstation_devices(sysfs="/sys"):
    """{HID_UNIQ: sysfs path} of every device hid-playstation holds: real pads and twins (ours or left over)"""
    out = {}
    for d in glob.glob(sysfs + "/bus/hid/drivers/playstation/*:*:*.*"):
        try:
            p = os.path.realpath(d)
            out.update({l[9:]: p for l in open(p + "/uevent").read().splitlines() if l.startswith("HID_UNIQ=")})
        except OSError:                     # appearing or going away
            pass
    return out


def bound_hidraw(uniq, sysfs="/sys"):
    """the twin's hidraw node once hid-playstation's probe has succeeded (the driver's link and hidraw appear before
    the probe runs; firmware_version only after it returned 0), else None"""
    p = playstation_devices(sysfs).get(uniq)
    try:
        if p and "/virtual/misc/uhid/" in p and os.path.exists(p + "/firmware_version"):
            return os.listdir(p + "/hidraw")[0]
    except (OSError, IndexError):
        pass
    return None


def twin(race, edges_path, max_seconds, summary=None, logfile=None, idle_only=False):
    out = open(logfile, "a", buffering=1) if logfile else sys.stdout      # a file: a pipe's reader can die first

    def log(m):
        print(time.strftime("%H:%M:%S"), m, file=out, flush=True)
    head, recs = read_rec(race)
    # Recorded times are CLOCK_REALTIME (the edges come from video timestamps); live ones are kept on CLOCK_MONOTONIC,
    # which NTP cannot step, and converted when they come in and go out.
    reports = [(real, for_replay(r)) for _, real, r in recs
               if r and r[0] == REPORT_BT and len(r) == 78 and crc_ok(SEED_INPUT, r)]
    if not reports or not head.get("race", {}).get("edges"):
        raise SystemExit(f"{race}: no valid Bluetooth input reports or no recorded edges (padreplay.py cut makes races)")
    features = {int(k, 16): bytes.fromhex(v) for k, v in head["features"].items()}
    for rid, size in ((0x05, 41), (PAIRING, 20), (0x20, 64)):      # what hid-playstation reads at probe, CRC-checked
        f = features.get(rid)
        if not f or len(f) != size or f[0] != rid or not crc_ok(SEED_FEATURE, f):
            raise SystemExit(f"{race}: feature report 0x{rid:02x} missing or corrupt: the kernel would refuse the twin")
    features[PAIRING], mac = twin_pairing(features[PAIRING])
    uevent = dict(l.split("=", 1) for l in head["uevent"].splitlines() if "=" in l)
    rp, idle = Replay(reports, head["race"]["edges"]), neutral(reports[0][1])
    if mac in playstation_devices():        # the kernel would refuse a second device with this MAC
        raise SystemExit(f"a pad with MAC {mac} exists already: a twin left by an earlier run?")
    fd = os.open("/dev/uhid", os.O_RDWR | os.O_CLOEXEC)
    stop = []
    for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(s, lambda *_: stop.append(1))
    uhid_create(fd, uevent.get("HID_NAME", "DualSense Wireless Controller"), uevent.get("HID_PHYS", ""), mac,
                bytes.fromhex(head["rdesc"]))
    t0, last = time.monotonic(), reports[0][1]
    end, next_idle, next_check, pending, ef, done, ready = t0 + max_seconds, 0.0, 0.0, b"", None, False, None

    def real_to_mono(ns):
        return ns - time.time_ns() + time.monotonic_ns()

    def dump():
        if summary:
            sm, off = rp.summary(), time.time_ns() - time.monotonic_ns()
            for e in sm["edges"]:
                e["live_ns"] = None if e["live_ns"] is None else e["live_ns"] + off
            with open(summary + ".new", "w") as f:
                json.dump(dict(sm, race=race, twin=mac, done=done), f)
            os.replace(summary + ".new", summary)
    try:
        while not stop and time.monotonic() < end:
            if ready is None and time.monotonic() >= next_check:
                ready, next_check = bound_hidraw(mac), time.monotonic() + 0.1
                if ready:
                    log(f"twin {mac} is {ready}: {len(reports)} reports over {(reports[-1][0] - reports[0][0]) / 1e9:.1f} s, "
                        f"{len(rp.edges)} recorded edges; idle until the race starts")
                elif time.monotonic() - t0 > 10:
                    raise SystemExit("hid-playstation did not bind the twin within 10 s (journalctl -k | grep 0CE6)")
            if ef is None and os.path.exists(edges_path):
                ef = open(edges_path, "rb")
            if ef:
                pending += ef.read()
                *lines, pending = pending.split(b"\n")
                for line in lines:
                    t, kind = line.split()
                    if kind == b"stop":
                        stop.append(1)
                    else:
                        log(rp.edge(real_to_mono(int(t)), kind.decode()))
                        dump()
            r = None if idle_only else rp.due(time.monotonic_ns())   # idle_only: something else drives (the game's AI)
            if r is not None:
                uhid_input(fd, r)
                last = r
            elif rp.delta is None or rp.done() or idle_only:
                if rp.done() and not done:
                    done, idle = True, neutral(last)  # at rest from where it was (the sensor clock goes on)
                    dump()
                    log("replay done; at rest until stopped")
                if time.monotonic() >= next_idle:       # a pad at rest still reports (this one ~456 Hz, in pairs)
                    uhid_input(fd, idle)
                    next_idle = time.monotonic() + 0.0022
            if select.select([fd], [], [], 0.001 if rp.delta is not None and not done else 0.002)[0]:
                if handle_event(fd, os.read(fd, EVENT_SIZE), features, log) == UHID_STOP:
                    raise SystemExit("the driver let the twin go" if ready else
                                     "hid-playstation refused the twin (journalctl -k | grep 0CE6)")
    finally:
        os.close(fd)                        # closing destroys the device
        log("twin removed")
        dump()


def info(rec):
    head, recs = read_rec(rec)
    reals = [real for _, real, _ in recs]
    good = sum(1 for _, _, r in recs if r and r[0] == REPORT_BT and crc_ok(SEED_INPUT, r))
    span = (reals[-1] - reals[0]) / 1e9 if reals else 0
    print(json.dumps({"reports": len(recs), "valid_bt": good, "seconds": round(span, 2),
                      "rate_hz": round(len(recs) / span, 1) if span else 0,
                      "first_realtime_ns": reals[0] if reals else None, "last_realtime_ns": reals[-1] if reals else None,
                      "device": head.get("device"),
                      "race": {k: (len(v) if k == "edges" else v) for k, v in head.get("race", {}).items()} or None}))


def selftest():
    # a fake Bluetooth report with a valid CRC: neutral() keeps the CRC valid and centres the sticks
    rep = bytearray(78)
    rep[0], rep[1] = REPORT_BT, 0x10
    rep[2:8] = bytes([0, 255, 10, 20, 200, 150])
    rep = with_crc(SEED_INPUT, bytes(rep))
    assert crc_ok(SEED_INPUT, rep)
    n = neutral(rep)
    assert crc_ok(SEED_INPUT, n) and n[2:6] == b"\x80" * 4 and n[6:8] == b"\x00\x00" and n[9] == 0x08
    ps = bytearray(rep)
    ps[11] |= 0x05                                               # PS and mute held
    fb = for_replay(with_crc(SEED_INPUT, bytes(ps)))
    assert crc_ok(SEED_INPUT, fb) and fb[54] == 0x2A and fb[11] == 0x04 and fb[:11] == rep[:11]
    # pairing: a made-up pad 14:3a:9a:00:00:01 (the CRC seed was checked against a real pad's report) -> a locally
    # administered MAC with a valid CRC
    p2, mac = twin_pairing(bytes.fromhex("090100009a3a140825000200000000004bb1344f"))
    assert p2.hex() == "090100009a3a160825000200000000007661c14b" and mac == "16:3a:9a:00:00:01", (p2.hex(), mac)
    assert CREATE2.size == 4376 and crc_ok(SEED_FEATURE, p2)
    # recording round trip
    import tempfile
    d = tempfile.mkdtemp()
    p = os.path.join(d, "r.rec")
    with open(p, "wb") as f:
        f.write(json.dumps({"features": {}, "rdesc": ""}).encode() + b"\n")
        for k in range(3):
            f.write(HDR_REC.pack(k, 1000 + k, len(rep)) + rep)
        f.write(HDR_REC.pack(9, 9, 78) + rep[:10])          # cut short: dropped
    head, recs = read_rec(p)
    assert len(recs) == 3 and recs[2][1] == 1002 and recs[0][2] == rep
    # letterbox edges: bar rows black and the picture below them -> "start" after HOLD frames, back -> "end"
    scene, bars = bytes([90]) * (GW * GH), bytes(16 * GW) + bytes([90]) * ((GH - 16) * GW)
    det = Letterbox()
    seq = [scene] * 3 + [bars] * 2 + [scene] + [bars] * 5 + [scene] * 4
    got = [e for e in (det.feed(k, fr) for k, fr in enumerate(seq)) if e]
    assert got == [(6, "start"), (11, "end")], got           # a 2-frame flicker is no edge
    # replay: anchor on the first recorded edge, skip ahead on a late edge, hold on an early one (times in ms)
    ms = 1_000_000
    rp = Replay([(t * ms, bytes([t])) for t in range(0, 100, 10)], [(25 * ms, "start"), (50 * ms, "end"), (80 * ms, "start")])
    assert rp.due(1000 * ms) is None and "ignored" in rp.edge(990 * ms, "end")
    rp.edge(1000 * ms, "start")                                  # live 1000 = recorded 25: the input held then (20)
    assert rp.due(1000 * ms) == bytes([20]) and rp.due(1004 * ms) is None and rp.due(1005 * ms) == bytes([30])
    assert "+3 ms" in rp.edge(1028 * ms, "end")                  # recorded 50 seen 3 ms late: 40 now due at 1018
    assert rp.due(1017 * ms) is None and rp.due(1018 * ms) == bytes([40])
    assert "unmatched" in rp.edge(1029 * ms, "end") and rp.j == 1   # an edge is matched once
    assert "-6 ms" in rp.edge(1052 * ms, "start")                # recorded 80 seen 6 ms early: skip to it
    assert rp.due(1052 * ms) == bytes([80]) and not rp.done() and rp.due(1062 * ms) == bytes([90]) and rp.done()
    sm = rp.summary()
    assert sm["corrections_ms"] == [3, -6] and [e["live_ns"] // ms for e in sm["edges"]] == [1000, 1028, 1052], sm
    rp2 = Replay([(0, b"x")], [(0, "start"), (50 * ms, "end")])
    rp2.edge(7 * ms, "start")
    assert rp2.summary()["edges"][1] == {"kind": "end", "recorded_s": 0.05, "matched": False, "live_ns": 57 * ms}
    print("ok")


def main(a):
    if a[:1] == ["--selftest"]:
        return selftest()
    if a[:1] == ["record"] and len(a) >= 3:
        return record(a[1], a[2], float(a[3]) if len(a) > 3 else 3600)
    if a[:1] == ["info"] and len(a) == 2:
        return info(a[1])
    if a[:1] == ["edges"] and len(a) == 2:
        return print(json.dumps(edges_of_video(a[1])))
    if a[:1] == ["watch"] and len(a) in (3, 4, 5):
        return watch(a[1], float(a[2]), *a[3:])
    if a[:1] == ["cut"] and len(a) >= 6:
        notes = dict(x.split("=", 1) for x in a[6:])
        return print(json.dumps(cut(a[1], a[2], int(a[3]), int(a[4]), json.load(open(a[5])), notes)))
    if a[:1] == ["races"] and len(a) == 6:
        loads = [(int(x), m) for x, m in (l.split() for l in open(a[3]) if l.strip())]
        for path, r in races(a[1], json.load(open(a[2])), loads, a[4], a[5]):
            print(f"{path}: {r['seconds']} s, {len(r['edges'])} edges")
        return
    if a[:1] == ["note"] and len(a) >= 3:
        return print(json.dumps(note(a[1], dict(x.split("=", 1) for x in a[2:]))))
    if a[:1] == ["twin"] and len(a) >= 4:
        opt = dict(zip(a[4::2], a[5::2]))
        return twin(a[1], a[2], float(a[3]), opt.get("--summary"), opt.get("--log"), opt.get("--idle") == "1")
    sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
