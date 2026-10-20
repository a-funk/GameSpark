/* Shows a Bluetooth DualSense to Proton as a USB one, so games that play haptics as USB audio (Sony's libScePad,
 * e.g. CONTROL Resonant) pair it with a sound card. LD_PRELOADed into the game's Wine processes (x86-64, run by FEX);
 * controller/dualsense-bt-haptics.py provides that sound card and turns what is played into it into Bluetooth
 * haptics.
 *
 * libScePad pairs a pad with its sound card by container ID. Proton's winebus.so derives a USB pad's container ID
 * from its USB device, and winepulse.so does the same for a sound card (from its sysfs.path); a Bluetooth pad gets a
 * random one. Here, for a DualSense (054C:0CE6) on Bluetooth:
 *   udev   its HID_ID reads bus 0003 (USB) and its HID_PHYS USB interface 3: winebus then takes the container ID
 *          from the USB device above it, the Bluetooth adapter, which the haptics sound card names too. The
 *          adapter's PRODUCT (ids and version), manufacturer and product strings read as the USB pad's, since
 *          winebus takes them for the pad's.
 *   ioctl  the report descriptor is the USB pad's; feature reports read lose their Bluetooth CRC (the USB pad
 *          has zeros there); feature reports written are dropped (USB setup that makes a Bluetooth pad disconnect).
 *   read   input report 0x31 (Bluetooth, 78 bytes) -> 0x01 (USB, 64 bytes), with the status bits a cabled pad
 *          sets (USB data and power plugged in).
 *   write  output report 0x02 (USB) -> 0x31 (Bluetooth, sequence number and CRC).
 * Every other device and call passes through untouched. DUALSENSE_BT_LOG=<file> logs what was changed.
 * Build: controller/dualsense-bt.sh build.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <linux/hidraw.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <unistd.h>

#include "dualsense-usb-rdesc.h" /* static const unsigned char usb_rdesc[] (the USB pad's, 289 bytes) */

#define BT_ID "HID_ID=0005:0000054C:00000CE6"
#define MAX_FD 65536

static unsigned char tracked[MAX_FD]; /* fd -> 1: a Bluetooth DualSense hidraw node shown as USB */
static unsigned int out_seq;

#define REAL(ret, name, ...)                                                                                 \
    static ret (*real_##name)(__VA_ARGS__);                                                                \
    if (!real_##name) real_##name = (ret (*)(__VA_ARGS__))dlsym(RTLD_NEXT, #name)

/* DUALSENSE_BT_LOG=<file>: a line per decision (devices shown as USB, the first converted reports) */
static FILE *log_file;
static pthread_once_t log_once = PTHREAD_ONCE_INIT;
static void log_open(void)
{
    const char *p = getenv("DUALSENSE_BT_LOG");
    if (!p || !*p) return;
    if (!(log_file = fopen(p, "ae"))) { /* glibc's internal open: not ours */
        dprintf(2, "dualsense-bt: cannot open %s, logging to stderr\n", p);
        log_file = stderr;
    }
}
static void note(const char *fmt, ...)
{
    pthread_once(&log_once, log_open);
    if (!log_file) return;
    va_list ap;
    va_start(ap, fmt);
    flockfile(log_file);
    fprintf(log_file, "%d ", (int)getpid());
    vfprintf(log_file, fmt, ap);
    fputc('\n', log_file);
    fflush(log_file);
    funlockfile(log_file);
    va_end(ap);
}

/* ------------------------------------------------------------------ CRC-32 as the DualSense uses it (zlib's,
 * over a one-byte seed then the report: 0xA2 output reports, 0x53 feature reports written) */
static uint32_t crc_table[256];
static pthread_once_t crc_once = PTHREAD_ONCE_INIT;
static void crc_init(void)
{
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
        crc_table[i] = c;
    }
}
static uint32_t ds_crc(uint8_t seed, const uint8_t *p, size_t n)
{
    pthread_once(&crc_once, crc_init);
    uint32_t c = crc_table[(0xFFFFFFFFu ^ seed) & 0xFF] ^ (0xFFFFFFFFu >> 8);
    while (n--) c = crc_table[(c ^ *p++) & 0xFF] ^ (c >> 8);
    return ~c;
}
static void put_le32(uint8_t *p, uint32_t v)
{
    p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24;
}

/* ------------------------------------------------------------------ which devices */
static int read_small(const char *path, char *buf, size_t size)
{
    FILE *f = fopen(path, "re"); /* glibc's internal open: not ours, no recursion */
    if (!f) return -1;
    size_t n = fread(buf, 1, size - 1, f);
    fclose(f);
    buf[n] = 0;
    return (int)n;
}

static int is_bt_dualsense_node(const char *path)
{
    char p[256], u[1024];
    if (!path || strncmp(path, "/dev/hidraw", 11)) return 0;
    snprintf(p, sizeof(p), "/sys/class/hidraw/%s/device/uevent", path + 5);
    return read_small(p, u, sizeof(u)) > 0 && strstr(u, BT_ID) != NULL;
}

/* Is syspath (a USB device) the one a Bluetooth DualSense hangs off, i.e. the Bluetooth adapter? */
static int carries_bt_dualsense(const char *syspath)
{
    char p[256], u[1024], real[PATH_MAX];
    size_t len = strlen(syspath);
    for (int i = 0; i < 64; i++) {
        snprintf(p, sizeof(p), "/sys/class/hidraw/hidraw%d/device/uevent", i);
        if (read_small(p, u, sizeof(u)) <= 0 || !strstr(u, BT_ID)) continue;
        snprintf(p, sizeof(p), "/sys/class/hidraw/hidraw%d/device", i);
        if (realpath(p, real) && !strncmp(real, syspath, len) && real[len] == '/') return 1;
    }
    return 0;
}

/* One line per process, to see which processes carry the library (DUALSENSE_BT_LOG only). */
__attribute__((constructor)) static void loaded(void)
{
    char exe[PATH_MAX];
    ssize_t n = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
    exe[n > 0 ? n : 0] = 0;
    if (getenv("DUALSENSE_BT_LOG")) note("loaded in %s", exe);
}

static void track(int fd, const char *path)
{
    if (fd < 0 || fd >= MAX_FD) return;
    tracked[fd] = is_bt_dualsense_node(path);
    if (tracked[fd]) note("open %s: fd %d shown as a USB pad", path, fd);
}

/* ------------------------------------------------------------------ open / close */
int open(const char *path, int flags, ...)
{
    REAL(int, open, const char *, int, ...);
    mode_t mode = 0;
    if (flags & (O_CREAT | O_TMPFILE)) { va_list ap; va_start(ap, flags); mode = va_arg(ap, mode_t); va_end(ap); }
    int fd = real_open(path, flags, mode);
    track(fd, path);
    return fd;
}
int open64(const char *path, int flags, ...)
{
    REAL(int, open64, const char *, int, ...);
    mode_t mode = 0;
    if (flags & (O_CREAT | O_TMPFILE)) { va_list ap; va_start(ap, flags); mode = va_arg(ap, mode_t); va_end(ap); }
    int fd = real_open64(path, flags, mode);
    track(fd, path);
    return fd;
}
int __open_2(const char *path, int flags)
{
    REAL(int, __open_2, const char *, int);
    int fd = real___open_2(path, flags);
    track(fd, path);
    return fd;
}
int __open64_2(const char *path, int flags)
{
    REAL(int, __open64_2, const char *, int);
    int fd = real___open64_2(path, flags);
    track(fd, path);
    return fd;
}
int close(int fd)
{
    REAL(int, close, int);
    if (fd >= 0 && fd < MAX_FD) tracked[fd] = 0;
    return real_close(fd);
}

/* ------------------------------------------------------------------ reports */
static ssize_t convert_input(uint8_t *dst, size_t count, const uint8_t *src, ssize_t n)
{
    if (n >= 65 && src[0] == 0x31 && count >= 64) { /* full Bluetooth report -> USB report 0x01 */
        dst[0] = 0x01;
        memcpy(dst + 1, src + 2, 63);
        dst[1 + 53] |= 0x18; /* status: USB data and USB power plugged in, as a cabled pad reports */
        return 64;
    }
    return 0; /* the short reports a pad sends before full mode: nothing a USB pad would send */
}

ssize_t read(int fd, void *buf, size_t count)
{
    REAL(ssize_t, read, int, void *, size_t);
    if (fd < 0 || fd >= MAX_FD || !tracked[fd]) return real_read(fd, buf, count);
    uint8_t tmp[1024];
    ssize_t n = real_read(fd, tmp, sizeof(tmp));
    return n <= 0 ? n : convert_input(buf, count, tmp, n);
}
ssize_t __read_chk(int fd, void *buf, size_t count, size_t buflen)
{
    REAL(ssize_t, __read_chk, int, void *, size_t, size_t);
    if (fd < 0 || fd >= MAX_FD || !tracked[fd]) return real___read_chk(fd, buf, count, buflen);
    uint8_t tmp[1024];
    REAL(ssize_t, read, int, void *, size_t);
    ssize_t n = real_read(fd, tmp, sizeof(tmp));
    return n <= 0 ? n : convert_input(buf, count < buflen ? count : buflen, tmp, n);
}

ssize_t write(int fd, const void *buf, size_t count)
{
    REAL(ssize_t, write, int, const void *, size_t);
    const uint8_t *r = buf;
    if (fd < 0 || fd >= MAX_FD || !tracked[fd] || count < 48 || r[0] != 0x02) return real_write(fd, buf, count);
    uint8_t bt[78] = {0};
    bt[0] = 0x31;
    bt[1] = (uint8_t)((__atomic_fetch_add(&out_seq, 1, __ATOMIC_RELAXED) & 0x0F) << 4); /* sequence, high nibble */
    bt[2] = 0x10;                                                                           /* tag */
    memcpy(bt + 3, r + 1, 47);                                                              /* the common block */
    put_le32(bt + 74, ds_crc(0xA2, bt, 74));
    ssize_t n = real_write(fd, bt, sizeof(bt));
    static int noted;
    if (!noted && n >= 0) {
        noted = 1;
        note("fd %d: first output report sent as Bluetooth 0x31", fd);
    }
    return n < 0 ? n : (ssize_t)count;
}

int ioctl(int fd, unsigned long request, ...)
{
    REAL(int, ioctl, int, unsigned long, ...);
    va_list ap;
    va_start(ap, request);
    void *arg = va_arg(ap, void *);
    va_end(ap);
    if (fd < 0 || fd >= MAX_FD || !tracked[fd] || _IOC_TYPE(request) != 'H') return real_ioctl(fd, request, arg);

    if (request == HIDIOCGRDESCSIZE) {
        *(int *)arg = (int)sizeof(usb_rdesc);
        return 0;
    }
    if (request == HIDIOCGRDESC) {
        struct hidraw_report_descriptor *d = arg;
        d->size = sizeof(usb_rdesc);
        memcpy(d->value, usb_rdesc, sizeof(usb_rdesc));
        note("fd %d: USB report descriptor", fd);
        return 0;
    }
    if (request == HIDIOCGRAWINFO) {
        int ret = real_ioctl(fd, request, arg);
        if (ret >= 0) ((struct hidraw_devinfo *)arg)->bustype = 3; /* BUS_USB */
        return ret;
    }
    if (_IOC_NR(request) == 0x07 && _IOC_DIR(request) == (_IOC_READ | _IOC_WRITE)) { /* HIDIOCGFEATURE(len) */
        int ret = real_ioctl(fd, request, arg);
        if (ret > 4) memset((uint8_t *)arg + ret - 4, 0, 4); /* the Bluetooth CRC; zeros on USB */
        return ret;
    }
    if (_IOC_NR(request) == 0x06 && _IOC_DIR(request) == (_IOC_READ | _IOC_WRITE)) { /* HIDIOCSFEATURE(len) */
        /* Never sent to the Bluetooth pad: what a game writes here is USB setup (libScePad writes feature 0x08,
         * 48 bytes, as it opens the pad), and over Bluetooth the pad answered it by dropping its link at once
         * (2026-10-13, every launch). Reported as written. */
        size_t len = _IOC_SIZE(request);
        note("fd %d: feature report 0x%02x (%zu bytes) not sent to the Bluetooth pad", fd,
             len ? ((const uint8_t *)arg)[0] : 0, len);
        return (int)len;
    }
    return real_ioctl(fd, request, arg);
}

/* ------------------------------------------------------------------ udev (winebus.so)
 * winebus.so links libudev but is itself dlopen()ed, so libudev is in no global scope: RTLD_NEXT and RTLD_DEFAULT
 * do not find it (calling the NULL they return crashed winebus's device scan). Ask the loaded copy itself. */
/* v with its line starting with key replaced by line (given without newline); a new string */
static char *replace_line(const char *v, const char *key, const char *line)
{
    size_t klen = strlen(key);
    char *out = malloc(strlen(v) + strlen(line) + 2), *o = out;
    int done = 0;
    for (const char *p = v; *p;) {
        const char *end = strchr(p, '\n');
        size_t len = end ? (size_t)(end - p + 1) : strlen(p);
        if (strncmp(p, key, klen)) {
            memcpy(o, p, len);
            o += len;
        } else if (!done++) {
            o += sprintf(o, "%s\n", line);
        }
        p += len;
    }
    *o = 0;
    return out;
}

static void *udev_sym(const char *name)
{
    void *p = dlsym(RTLD_NEXT, name), *h;
    if (!p && (h = dlopen("libudev.so.1", RTLD_NOW | RTLD_NOLOAD))) {
        p = dlsym(h, name);
        dlclose(h);
    }
    return p;
}

const char *udev_device_get_sysattr_value(void *dev, const char *attr)
{
    static const char *(*real)(void *, const char *);
    static const char *(*get_syspath)(void *);
    if (!real) real = (const char *(*)(void *, const char *))udev_sym("udev_device_get_sysattr_value");
    if (!get_syspath) get_syspath = (const char *(*)(void *))udev_sym("udev_device_get_syspath");
    if (!real) {
        note("udev: libudev not found, %s not read", attr ? attr : "(null)");
        return NULL;
    }
    const char *v = real(dev, attr);
    if (!attr) return v;

    if (v && !strcmp(attr, "uevent") && strstr(v, BT_ID)) { /* the pad's HID device: bus USB, interface 3 */
        char *s = strdup(v), *t;
        memcpy(strstr(s, BT_ID) + 7, "0003", 4);
        t = replace_line(s, "HID_PHYS=", "HID_PHYS=usb-gamespark-1/input3"); /* winebus: "...&MI_03" as on USB */
        free(s);
        note("udev: %s reads bus USB, interface 3", get_syspath ? get_syspath(dev) : "the pad");
        return t; /* a few small strings per enumeration, kept: the caller does not free them */
    }
    if (strcmp(attr, "uevent") && strcmp(attr, "manufacturer") && strcmp(attr, "product") && strcmp(attr, "serial"))
        return v;
    const char *sys = get_syspath ? get_syspath(dev) : NULL;
    if (!sys || !carries_bt_dualsense(sys)) return v;
    note("udev: %s %s read as the pad's", sys, attr);
    if (!strcmp(attr, "manufacturer")) return "Sony Interactive Entertainment";
    if (!strcmp(attr, "product")) return "DualSense Wireless Controller";
    if (!strcmp(attr, "serial")) return NULL;
    if (v && !strcmp(attr, "uevent")) /* the adapter's: winebus takes its PRODUCT= as the pad's ids and version */
        return replace_line(v, "PRODUCT=", "PRODUCT=54c/ce6/100"); /* the USB pad's (bcdDevice 1.00) */
    return v;
}

#ifdef SELFTEST
/* x86_64-linux-gnu-gcc -DSELFTEST ... -o selftest && FEX ./selftest */
int main(void)
{
    /* an output report the game wrote on the Spark (both triggers' effect off), rebuilt: same bytes, same CRC */
    uint8_t usb[48] = {0x02, 0x0C, 0x40}, bt[78] = {0x31, 0x00, 0x10};
    usb[1 + 10] = usb[1 + 21] = 0x05;
    memcpy(bt + 3, usb + 1, 47);
    uint32_t c = ds_crc(0xA2, bt, 74);
    if (c != 0x07C5CAF9u) { printf("FAIL crc %08x\n", c); return 1; }
    uint8_t in[78] = {0x31, 0x40}, out[64];
    for (int i = 2; i < 78; i++) in[i] = (uint8_t)i;
    if (convert_input(out, sizeof(out), in, 78) != 64 || out[0] != 1 || out[1] != 2 || out[63] != 64) {
        printf("FAIL input\n");
        return 1;
    }
    if (sizeof(usb_rdesc) != 289) { printf("FAIL descriptor size %zu\n", sizeof(usb_rdesc)); return 1; }
    char *r = replace_line("A=1\nPRODUCT=13d3/3630/100\nB=2", "PRODUCT=", "PRODUCT=54c/ce6/100");
    if (strcmp(r, "A=1\nPRODUCT=54c/ce6/100\nB=2")) { printf("FAIL replace_line: %s\n", r); return 1; }
    free(r);

    /* udev with libudev dlopen()ed, out of every global scope as winebus.so has it: values pass through, and a
     * Bluetooth DualSense's HID device (when one is connected) reads bus USB */
    void *h = dlopen("libudev.so.1", RTLD_NOW);
    if (!h) { printf("FAIL no libudev.so.1: %s\n", dlerror()); return 1; }
    void *(*u_new)(void) = (void *(*)(void))dlsym(h, "udev_new");
    void *(*from_syspath)(void *, const char *) = (void *(*)(void *, const char *))dlsym(h, "udev_device_new_from_syspath");
    void *(*parent)(void *, const char *, const char *) =
        (void *(*)(void *, const char *, const char *))dlsym(h, "udev_device_get_parent_with_subsystem_devtype");
    void *udev = u_new();
    const char *v = udev_device_get_sysattr_value(from_syspath(udev, "/sys/class/mem/null"), "uevent");
    if (!v || !strstr(v, "DEVNAME=null")) { printf("FAIL udev pass-through: %s\n", v ? v : "(null)"); return 1; }
    for (int i = 0; i < 64; i++) {
        char p[64], u[1024];
        snprintf(p, sizeof(p), "/sys/class/hidraw/hidraw%d/device/uevent", i);
        if (read_small(p, u, sizeof(u)) <= 0 || !strstr(u, BT_ID)) continue;
        snprintf(p, sizeof(p), "/sys/class/hidraw/hidraw%d", i);
        void *hid = parent(from_syspath(udev, p), "hid", NULL);
        v = hid ? udev_device_get_sysattr_value(hid, "uevent") : NULL;
        if (!v || !strstr(v, "HID_ID=0003:0000054C:00000CE6") || !strstr(v, "/input3\n")) {
            printf("FAIL hidraw%d not shown as USB interface 3\n", i);
            return 1;
        }
        printf("hidraw%d (Bluetooth DualSense) reads bus USB, interface 3\n", i);
    }
    printf("selftest ok\n");
    return 0;
}
#endif
