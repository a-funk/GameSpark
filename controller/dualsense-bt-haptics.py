#!/usr/bin/env python3
# DualSense haptics over Bluetooth for games that play them as USB audio (Sony's libScePad, e.g. CONTROL Resonant).
#
# On USB a DualSense is also a 4-channel sound card: speaker on channels 1-2, haptic actuators on 3-4. Over Bluetooth
# that card does not exist. This makes a stand-in PipeWire sink that Proton takes for it ("Wireless Controller": bus
# usb, Sony's vendor and product ids) with the container ID of the pad as libdualsense-bt.so shows it to Proton (both
# derived from the Bluetooth adapter's USB device, named by sysfs.path), and sends channels 3-4 of what the game
# plays into it to the pad as Bluetooth haptics: 48 kHz -> 3 kHz signed 8-bit, report 0x32 every 10.67 ms. That
# report format is from SAxense by Egor Vorontsov (https://github.com/egormanga/SAxense, MPL-2.0). The speaker
# channels are dropped. Started by controller/dualsense-bt.sh (tools/launch.sh, DUALSENSE_BT_HAPTICS=1).
#
#   dualsense-bt-haptics.py run --while-pid PID   until PID exits (the game's launch chain)
#   dualsense-bt-haptics.py test                  a 2 s pattern straight to the pad (left, right, both pulsing)
#   dualsense-bt-haptics.py --selftest
import glob, os, subprocess, sys, threading, time, zlib

SINK = 'gamespark.dualsense-bt-haptics'
HAPTIC_RATE, HAPTIC_FRAMES = 3000, 32                  # one report: 32 stereo frames, 10.67 ms

def log(*a):
    print(time.strftime('%H:%M:%S'), *a, file=sys.stderr, flush=True)

def crc_le(seed, data):
    """CRC-32 the DualSense appends to Bluetooth reports: zlib's CRC over a one-byte seed then the report."""
    return zlib.crc32(bytes([seed]) + bytes(data)).to_bytes(4, 'little')

def haptics_report(samples, counter):
    """Bluetooth report 0x32 (142 bytes with id): 32 stereo signed 8-bit frames at 3 kHz (SAxense's layout)."""
    assert len(samples) == 2 * HAPTIC_FRAMES
    b = bytearray(142)
    b[0] = 0x32
    b[2:4] = bytes([0x91, 7])                             # sub-packet 0x11 (sized), 7 bytes
    b[4:11] = bytes([0xFE, 0, 0, 0, 0, 0xFF, counter & 0xFF])
    b[11:13] = bytes([0x92, 2 * HAPTIC_FRAMES])           # sub-packet 0x12 (sized): the samples
    b[13:13 + 2 * HAPTIC_FRAMES] = samples
    b[138:142] = crc_le(0xA2, b[:138])
    return bytes(b)

class Decimator:
    """48 kHz -> 3 kHz (factor 16) for two channels: windowed-sinc low-pass at 1.3 kHz, then every 16th sample."""
    def __init__(self, taps=255, factor=16, cutoff=1300.0, rate=48000.0):
        import numpy as np
        self.np, self.factor = np, factor
        n = np.arange(taps) - (taps - 1) / 2
        h = np.sinc(2 * cutoff / rate * n) * np.hanning(taps)
        self.h = h / h.sum()
        self.tail = np.zeros((taps - 1, 2))
        self.phase = 0

    def __call__(self, x):
        np = self.np
        buf = np.concatenate([self.tail, x])
        self.tail = buf[-(len(self.h) - 1):]
        y = np.stack([np.convolve(buf[:, c], self.h, 'valid') for c in (0, 1)], axis=1)
        out = y[self.phase::self.factor]
        self.phase = (self.phase - len(x)) % self.factor
        return out

def to_s8(y, gain=1.0):
    import numpy as np
    return np.clip(np.round(y * gain * 127.0), -127, 127).astype(np.int8).tobytes()

def bluetooth_pad():
    """/dev/hidrawN of a DualSense connected over Bluetooth, or None."""
    for h in sorted(glob.glob('/sys/class/hidraw/hidraw*')):
        try:
            if 'HID_ID=0005:0000054C:00000CE6' in open(h + '/device/uevent').read():
                return '/dev/' + os.path.basename(h)
        except OSError:
            pass
    return None

def adapter_path():
    """sysfs path (without /sys) under the Bluetooth adapter's USB device: Proton's winepulse looks up the USB
    device above it for the container ID, as winebus does for the pad."""
    return os.path.realpath('/sys/class/bluetooth/hci0')[len('/sys'):]

class Haptics:
    def __init__(self, gain):
        self.gain, self.stop = gain, threading.Event()
        self.buf, self.lock = bytearray(), threading.Lock()
        self.fd, self.node = None, None
        props = ('{ media.class=Audio/Sink node.name=%s node.description="DualSense Wireless Controller (Bluetooth '
                 'haptics)" node.autoconnect=false device.bus=usb device.vendor.id=0x054c device.product.id=0x0ce6 '
                 'device.class=sound sysfs.path="%s" priority.session=1 priority.driver=1 }' % (SINK, adapter_path()))
        self.rec = subprocess.Popen(['pw-record', '-P', props, '--rate', '48000', '--channels', '4', '--channel-map',
                                     'FL,FR,RL,RR', '--format', 's16', '--latency', '512', '-'],
                                    stdout=subprocess.PIPE)

    def pad_fd(self):
        """The pad's hidraw node, reopened after it reconnects; None while it is away."""
        if self.fd is None or not os.path.exists(self.node or ''):
            if self.fd is not None:
                os.close(self.fd)
                self.fd = None
            self.node = bluetooth_pad()
            if self.node:
                self.fd = os.open(self.node, os.O_WRONLY)
                log('haptics to', self.node)
        return self.fd

    def capture(self):
        import numpy as np
        dec, pending, frame = Decimator(), b'', 8          # 4 channels x 2 bytes
        while not self.stop.is_set():
            chunk = self.rec.stdout.read1(4096)
            if not chunk:
                break
            pending += chunk
            n = len(pending) // frame * frame
            x = np.frombuffer(pending[:n], dtype='<i2').reshape(-1, 4)[:, 2:4] / 32768.0
            pending = pending[n:]
            s8 = to_s8(dec(x), self.gain)
            with self.lock:
                self.buf += s8
                if len(self.buf) > 12 * 2 * HAPTIC_FRAMES:   # over ~128 ms behind: keep the newest ~85 ms
                    del self.buf[:len(self.buf) - 8 * 2 * HAPTIC_FRAMES]
        self.stop.set()

    def send(self):
        """Reports at the pad's pace. The game keeps its stream open and mostly silent: send only while there is
        sound, plus half a second of silence to let the actuators settle."""
        period, size = HAPTIC_FRAMES / HAPTIC_RATE, 2 * HAPTIC_FRAMES
        counter, active, quiet_since, nxt = 0, False, 0.0, 0.0
        while not self.stop.is_set():
            now = time.monotonic()
            with self.lock:
                if not active:
                    sound = self.buf.lstrip(b'\0')
                    if sound:
                        del self.buf[:(len(self.buf) - len(sound)) & ~1]
                        if len(self.buf) >= 2 * size:      # start with ~21 ms of slack against capture jitter
                            active, quiet_since, nxt = True, now, now
                    else:
                        self.buf.clear()
                chunk = None
                if active:
                    chunk = bytes(self.buf[:size]).ljust(size, b'\0')
                    del self.buf[:size]
            if not active:
                time.sleep(period / 2)
                continue
            if any(chunk):
                quiet_since = now
            elif now - quiet_since > 0.5:
                active = False
                continue
            fd = self.pad_fd()
            if fd is not None:
                try:
                    os.write(fd, haptics_report(chunk, counter))
                except OSError:                            # pad gone: reopen on the next report
                    os.close(fd)
                    self.fd = None
            counter += 1
            nxt += period
            delay = nxt - time.monotonic()
            if delay > 0:
                time.sleep(delay)
            elif delay < -0.05:                            # fell behind (a scheduling hiccup): no catch-up burst
                nxt = time.monotonic()

    def run(self, while_pid):
        for fn in (self.capture, self.send):
            threading.Thread(target=fn, daemon=True).start()
        try:
            while not self.stop.wait(1):
                if while_pid and not os.path.exists('/proc/%d' % while_pid):
                    break
        finally:
            self.stop.set()
            self.rec.terminate()
            log('stopped')

def test():
    import numpy as np
    node = bluetooth_pad()
    if not node:
        sys.exit('no DualSense connected over Bluetooth')
    fd = os.open(node, os.O_WRONLY)
    t = np.arange(int(2.0 * HAPTIC_RATE)) / HAPTIC_RATE
    left = np.where(t < 0.7, np.sin(2 * np.pi * 150 * t), 0)
    right = np.where((t >= 0.7) & (t < 1.4), np.sin(2 * np.pi * 60 * t), 0)
    pulse = np.where(t >= 1.4, np.sin(2 * np.pi * 100 * t) * (np.sin(2 * np.pi * 8 * t) > 0), 0)
    s = to_s8(np.stack([left + pulse, right + pulse], axis=1) * 0.8)
    size, nxt = 2 * HAPTIC_FRAMES, time.monotonic()
    for i in range(0, len(s) - size + 1, size):
        os.write(fd, haptics_report(s[i:i + size], i // size))
        nxt += HAPTIC_FRAMES / HAPTIC_RATE
        time.sleep(max(0, nxt - time.monotonic()))
    for i in range(3):
        os.write(fd, haptics_report(bytes(size), 200 + i))
    print('sent %d reports to %s' % (len(s) // size, node))

def selftest():
    import numpy as np
    assert zlib.crc32(b'\xa2') == 0xEADA2D49              # SAxense's seed constant is zlib's CRC of 0xA2
    h = haptics_report(bytes(range(64)), 5)
    assert len(h) == 142 and h[13:77] == bytes(range(64)) and h[10] == 5 and h[138:] == crc_le(0xA2, h[:138])
    d = Decimator()
    t = np.arange(48000) / 48000.0
    x = np.stack([np.sin(2 * np.pi * 150 * t), np.sin(2 * np.pi * 5000 * t)], axis=1) * 0.5
    y = np.concatenate([d(x[i:i + 960]) for i in range(0, 48000, 960)])
    assert len(y) == 3000
    rms = np.sqrt((y[500:] ** 2).mean(axis=0))
    assert abs(rms[0] - 0.5 / np.sqrt(2)) < 0.02, rms      # 150 Hz passes
    assert rms[1] < 0.01, rms                               # 5 kHz (it would alias) is removed
    print('selftest ok')

if __name__ == '__main__':
    a = sys.argv[1:]
    if a[:1] == ['--selftest']:
        selftest()
    elif a[:1] == ['test']:
        test()
    elif a[:1] == ['run']:
        pid = int(a[a.index('--while-pid') + 1]) if '--while-pid' in a else 0
        Haptics(float(os.environ.get('DUALSENSE_HAPTICS_GAIN', '1.0'))).run(pid)
    else:
        sys.exit('usage: dualsense-bt-haptics.py run [--while-pid PID] | test | --selftest')
