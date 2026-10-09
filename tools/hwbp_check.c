/* x86 hardware execute breakpoint check, the pattern Denuvo uses (docs/FINDINGS.md, Galactic Racer): arm DR0 on a
 * function of this thread with SetThreadContext, call it, expect EXCEPTION_SINGLE_STEP at the function's address in a
 * vectored handler, which clears DR7 and continues. Exit code 0 = pass.
 * Build: x86_64-w64-mingw32-gcc -O2 -mwindows -o hwbp_check.exe tools/hwbp_check.c
 * Run (Proton's Wine; the patched FEX needs FEX_NEEDSSECCOMP=1 FEX_GSHWBP=1):
 *   FEX_NEEDSSECCOMP=1 FEX_GSHWBP=1 ~/.local/share/gamespark/fex/current/bin/FEX /bin/bash -c \
 *     'WINEPREFIX=... LD_LIBRARY_PATH=<proton>/files/lib/x86_64-linux-gnu <proton>/files/bin/wine hwbp_check.exe Z:/tmp/hw.txt'
 * Stock FEX 2610: SetThreadContext fails (error 5) and nothing fires. */
#include <windows.h>
#include <stdio.h>

static volatile LONG hits;
static volatile int addr_ok;
static volatile DWORD64 seen_dr6, seen_dr7;
static void *target;

__attribute__((noinline)) int target_fn(int x)
{
    return x * 3 + 1;
}

static LONG CALLBACK veh(EXCEPTION_POINTERS *e)
{
    if (e->ExceptionRecord->ExceptionCode != EXCEPTION_SINGLE_STEP) return EXCEPTION_CONTINUE_SEARCH;
    InterlockedIncrement(&hits);
    addr_ok = e->ExceptionRecord->ExceptionAddress == target;
    seen_dr6 = e->ContextRecord->Dr6;
    seen_dr7 = e->ContextRecord->Dr7;
    e->ContextRecord->Dr0 = 0;
    e->ContextRecord->Dr7 = 0;   /* disarm, then resume at the breakpoint address */
    return EXCEPTION_CONTINUE_EXECUTION;
}

int main(int argc, char **argv)
{
    FILE *out = argc > 1 ? fopen(argv[1], "w") : stdout;
    CONTEXT c = { .ContextFlags = CONTEXT_DEBUG_REGISTERS };
    CONTEXT g = { .ContextFlags = CONTEXT_DEBUG_REGISTERS };
    int (*volatile fn)(int) = target_fn;
    BOOL set_ok, get_ok;
    int r1, r2;

    target = (void *)target_fn;
    AddVectoredExceptionHandler(1, veh);
    c.Dr0 = (DWORD64)target_fn;
    c.Dr7 = 1;                     /* L0, execute, length 1 */
    set_ok = SetThreadContext(GetCurrentThread(), &c);
    fprintf(out, "SetThreadContext: %s (error %lu)\n", set_ok ? "ok" : "FAILED", set_ok ? 0 : GetLastError());
    get_ok = GetThreadContext(GetCurrentThread(), &g);
    fprintf(out, "GetThreadContext: %s Dr0=%llx Dr7=%llx\n", get_ok ? "ok" : "FAILED",
            (unsigned long long)g.Dr0, (unsigned long long)g.Dr7);
    fflush(out);
    r1 = fn(5);                    /* should trap once at target_fn */
    r2 = fn(6);                    /* disarmed: no trap */
    fprintf(out, "calls returned %d %d (expect 16 19); single-step hits %ld (expect 1); address %s; Dr6=%llx Dr7=%llx\n",
            r1, r2, hits, addr_ok ? "ok" : "WRONG", (unsigned long long)seen_dr6, (unsigned long long)seen_dr7);
    fclose(out);
    return (set_ok && hits == 1 && addr_ok && r1 == 16 && r2 == 19) ? 0 : 1;
}
