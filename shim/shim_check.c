/* Check for shim/shim.c: polls InternetGetConnectedState at 10 Hz for 7 s, as The Witcher 3 does, and reports the
 * slowest call after the first. With the shim every call is a cache read (well under 1 ms); without it, or with a
 * refresh on the caller's thread, the slowest call is Wine's full cost (5 ms and up on the GB10).
 * Build: x86_64-w64-mingw32-gcc -O2 -mwindows -o shim_check.exe shim/shim_check.c -lwininet -lpowrprof
 * Run:   with the shim's powrprof.dll next to it, WINEDLLOVERRIDES=powrprof=n,b wine shim_check.exe out.txt
 *        (exit status 0: pass) */
#include <windows.h>
#include <wininet.h>
#include <powrprof.h>
#include <stdio.h>

int main(int argc, char **argv)
{
    LARGE_INTEGER f, a, b;
    SYSTEM_POWER_CAPABILITIES caps;
    double worst = 0, t;
    DWORD flags;
    int i;

    if (argc > 1 && !freopen(argv[1], "w", stdout)) return 2;
    CallNtPowerInformation(SystemPowerCapabilities, NULL, 0, &caps, sizeof(caps));   /* imports powrprof, as the game does */
    QueryPerformanceFrequency(&f);
    InternetGetConnectedState(&flags, 0);
    for (i = 0; i < 70; i++) {
        Sleep(100);
        QueryPerformanceCounter(&a);
        InternetGetConnectedState(&flags, 0);
        QueryPerformanceCounter(&b);
        t = (double)(b.QuadPart - a.QuadPart) * 1e3 / (double)f.QuadPart;
        if (t > worst) worst = t;
    }
    printf("slowest InternetGetConnectedState over 7 s at 10 Hz: %.3f ms (%s)\n", worst, worst < 1 ? "pass" : "FAIL");
    return worst >= 1;
}
