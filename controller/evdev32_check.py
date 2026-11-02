"""Does FEX hand 32-bit x86 programs the 32-bit struct input_event? The 32-bit Steam client depends on it for every
controller it reads through evdev (controller/60-gamespark-xbox-hidraw.rules has the workaround).

  python3 -I controller/evdev32_check.py      exit 0: 16-byte events (fixed); 1: 24-byte events (Steam misreads)

Creates a uinput pad, runs a tiny static 32-bit x86 program under FEX that read()s 40 bytes from its event node,
then presses the pad's D-pad. A 32-bit program expects 16-byte events (two fit in 40 bytes); the kernel only
converts for real 32-bit tasks, and FEX runs 32-bit x86 code in a 64-bit process.
"""
import fcntl, os, struct, subprocess, sys, tempfile, time

BASE, HDR = 0x08048000, 52 + 32


def elf32_reader(path):
    """open(path), read(fd, buf, 40), write(1, buf, n), exit(n); the buffer on its own page (FEX write-protects code)."""
    buf, path = BASE + 0x2000, path.encode() + b"\0"
    def code(path_addr):
        a = struct.pack("<I", path_addr); b = struct.pack("<I", buf)
        return (b"\xb8\x05\0\0\0\xbb" + a + b"\x31\xc9\xcd\x80\x89\xc6"                     # open; esi = fd
                b"\xb8\x03\0\0\0\x89\xf3\xb9" + b + b"\xba\x28\0\0\0\xcd\x80\x89\xc7"      # read 40; edi = n
                b"\xb8\x04\0\0\0\xbb\x01\0\0\0\xb9" + b + b"\x89\xfa\xcd\x80"              # write(1, buf, n)
                b"\x89\xfb\xb8\x01\0\0\0\xcd\x80")                                         # exit(n)
    body = code(BASE + HDR + len(code(0))) + path
    ehdr = b"\x7fELF\x01\x01\x01" + b"\0" * 9 + struct.pack("<HHIIIIIHHHHHH", 2, 3, 1, BASE + HDR, 52, 0, 0, 52, 32, 1, 0, 0, 0)
    return ehdr + struct.pack("<8I", 1, 0, BASE, BASE, HDR + len(body), 0x3000, 7, 0x1000) + body


def pad():
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    for ev in (1, 3):
        fcntl.ioctl(fd, 0x40045564, ev)                     # UI_SET_EVBIT: EV_KEY, EV_ABS
    fcntl.ioctl(fd, 0x40045565, 0x130)                      # UI_SET_KEYBIT: BTN_SOUTH (makes it a joystick)
    fcntl.ioctl(fd, 0x40045567, 0x10)                       # UI_SET_ABSBIT: ABS_HAT0X
    mx, mn = [0] * 64, [0] * 64
    mx[0x10], mn[0x10] = 1, -1
    os.write(fd, struct.pack("80sHHHHi", b"GameSpark evdev32 check", 3, 0x1234, 0x5678, 1, 0)
             + struct.pack("64i", *mx) + struct.pack("64i", *mn) + bytes(4 * 128))
    fcntl.ioctl(fd, 0x5501)                                 # UI_DEV_CREATE
    return fd


def main():
    fd = pad()
    try:
        time.sleep(1)
        node = max((f"/dev/input/{n}" for n in os.listdir("/sys/class/input") if n.startswith("event")
                    and open(f"/sys/class/input/{n}/device/name").read().strip() == "GameSpark evdev32 check"))
        with tempfile.TemporaryDirectory() as d:
            exe = os.path.join(d, "evread32")
            open(exe, "wb").write(elf32_reader(node)); os.chmod(exe, 0o755)
            p = subprocess.Popen(["FEX", exe], stdout=subprocess.PIPE)
            time.sleep(2)                                   # FEX start-up; the reader blocks in read()
            os.write(fd, struct.pack("qqHHi", 0, 0, 3, 0x10, 1) + struct.pack("qqHHi", 0, 0, 0, 0, 0))
            out = p.communicate(timeout=20)[0]
    finally:
        fcntl.ioctl(fd, 0x5502); os.close(fd)               # UI_DEV_DESTROY
    if len(out) == 32 and struct.unpack_from("<iiHHi", out)[2:] == (3, 0x10, 1):
        print("ok: 16-byte events; FEX converts input_event for 32-bit programs"); return 0
    if len(out) == 24 and struct.unpack_from("<qqHHi", out)[2:] == (3, 0x10, 1):
        print("FEX passes 64-bit input_event (24 bytes) to 32-bit programs: the 32-bit Steam misreads evdev pads"); return 1
    print(f"unexpected: {len(out)} bytes {out[:48].hex()}"); return 2


if __name__ == "__main__":
    sys.exit(main())
