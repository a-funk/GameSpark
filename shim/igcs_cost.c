/* Times wininet!InternetGetConnectedState and the iphlpapi calls Wine answers it with (docs/FINDINGS.md, The
 * Witcher 3). Not part of the shim: a reproducer for the Wine cost the shim works around.
 * Build: x86_64-w64-mingw32-gcc -O2 -mwindows -o igcs_cost.exe shim/igcs_cost.c -lwininet -liphlpapi
 * Run:   wine igcs_cost.exe [calls [outfile [seconds]]]   (-mwindows: no console, so give an outfile under Proton)
 *        calls: per measurement (default 50); outfile: default stdout; seconds: then poll
 *        InternetGetConnectedState at 10 Hz (as The Witcher 3 does) for that long and measure again. */
#include <winsock2.h>
#include <windows.h>
#include <wininet.h>
#include <iphlpapi.h>
#include <stdio.h>
#include <stdlib.h>

static ULONG size;
static IP_ADAPTER_ADDRESSES *aa;
static DWORD flags;
static GUID guid;

static double now_ms(void)
{
    LARGE_INTEGER f, c;
    QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&c);
    return (double)c.QuadPart * 1e3 / (double)f.QuadPart;
}

static void igcs(void) { InternetGetConnectedState(&flags, 0); }
static void gaa(void) { ULONG s = size; GetAdaptersAddresses(AF_UNSPEC, GAA_FLAG_INCLUDE_GATEWAYS, NULL, aa, &s); }
static void luid2guid(void) { ConvertInterfaceLuidToGuid(&aa->Luid, &guid); }

static void time_it(const char *name, void (*f)(void), int n)
{
    double sum = 0, worst = 0, t;
    int i;
    for (i = 0; i < n; i++) {
        t = now_ms();
        f();
        t = now_ms() - t;
        sum += t;
        if (t > worst) worst = t;
    }
    printf("%-34s mean %8.3f ms   max %8.3f ms   (%d calls)\n", name, sum / n, worst, n);
}

static void measure(int n)
{
    IP_ADAPTER_ADDRESSES *a;
    int adapters = 0;

    size = 0;
    GetAdaptersAddresses(AF_UNSPEC, GAA_FLAG_INCLUDE_GATEWAYS, NULL, NULL, &size);
    size *= 2;
    free(aa);
    aa = malloc(size);
    gaa();
    for (a = aa; a; a = a->Next) adapters++;
    printf("%d adapters\n", adapters);
    time_it("InternetGetConnectedState", igcs, n);
    time_it("GetAdaptersAddresses(GATEWAYS)", gaa, n);
    time_it("ConvertInterfaceLuidToGuid", luid2guid, n * 10);
}

int main(int argc, char **argv)
{
    int n = argc > 1 ? atoi(argv[1]) : 50;
    DWORD end;

    if (argc > 2 && !freopen(argv[2], "w", stdout)) return 1;
    setvbuf(stdout, NULL, _IONBF, 0);
    measure(n);
    if (argc > 3) {
        for (end = GetTickCount() + atoi(argv[3]) * 1000; GetTickCount() < end; Sleep(100)) igcs();
        printf("after polling for %s s:\n", argv[3]);
        measure(n);
    }
    return 0;
}
