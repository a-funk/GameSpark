/* Raise the CPU faults Denuvo's startup checks raise (docs/FINDINGS.md, Galactic Racer) and compare what Windows code
 * sees under Wine + FEX with what a real x86-64 CPU gives. Prints one line per fault; exit code = mismatches.
 * Build: x86_64-w64-mingw32-gcc -O2 -mwindows -o faultprobe.exe tools/faultprobe.c
 * Run:   FEX /bin/bash -c 'WINEPREFIX=... wine faultprobe.exe Z:/tmp/fp.txt'   (-mwindows: write to a file, not a console)
 * FEX 2610: 2 mismatches (non-canonical addresses). */
#include <windows.h>
#include <stdio.h>

static DWORD code, nparams;
static ULONG_PTR info0, info1;
static int skip;   /* bytes to step over the faulting instruction */

static LONG CALLBACK veh(EXCEPTION_POINTERS *e)
{
    code = e->ExceptionRecord->ExceptionCode;
    nparams = e->ExceptionRecord->NumberParameters;
    info0 = nparams > 0 ? e->ExceptionRecord->ExceptionInformation[0] : 0;
    info1 = nparams > 1 ? e->ExceptionRecord->ExceptionInformation[1] : 0;
    e->ContextRecord->Rip += skip;
    return EXCEPTION_CONTINUE_EXECUTION;
}

/* Each stub faults on its first instruction, which is `len` bytes long, then returns. */
__asm__(".globl load8\nload8:\n movq (%rcx), %rax\n ret\n"                       /* 48 8b 01 */
        ".globl do_ud2\ndo_ud2:\n ud2\n ret\n"
        ".globl do_evex\ndo_evex:\n .byte 0x62,0xf2,0x6f,0x28,0x72,0xd9\n ret\n"   /* vcvtne2ps2bf16 (AVX512-BF16) */
        ".globl do_serialize\ndo_serialize:\n .byte 0x0f,0x01,0xe8\n ret\n"
        ".globl do_hlt\ndo_hlt:\n hlt\n ret\n"
        ".globl do_in\ndo_in:\n inb %dx, %al\n ret\n");
ULONG_PTR load8(ULONG_PTR addr);
void do_ud2(void), do_evex(void), do_serialize(void), do_hlt(void), do_in(void);

static FILE *out;
static int bad;

static void check(const char *name, DWORD want_code, int want_params, ULONG_PTR want_info1)
{
    int ok = code == want_code && (!want_params || (nparams >= 2 && info1 == want_info1));
    fprintf(out, "%-34s got %08lx", name, code);
    if (nparams >= 2) fprintf(out, " info[0]=%llx info[1]=%016llx", (unsigned long long)info0, (unsigned long long)info1);
    fprintf(out, "  expect %08lx", want_code);
    if (want_params) fprintf(out, " info[1]=%016llx", (unsigned long long)want_info1);
    fprintf(out, "  %s\n", ok ? "ok" : "DIFFERS");
    bad += !ok;
}

#define RUN(len_, call) (code = 0, nparams = 0, skip = (len_), call)

int main(int argc, char **argv)
{
    static volatile ULONG_PTR word = 42;
    ULONG_PTR tagged = 0xFF00000000000000ull | (ULONG_PTR)&word;

    out = argc > 1 ? fopen(argv[1], "w") : stdout;
    if (!out) return 99;
    AddVectoredExceptionHandler(1, veh);

    /* x86-64: an address whose bits 63:47 are not all equal raises #GP; Windows reports an access violation at
     * address -1. A kernel-half (canonical) address raises #PF and reports the address itself. */
    RUN(3, load8(0x10));                  check("user address 0x10", EXCEPTION_ACCESS_VIOLATION, 1, 0x10);
    RUN(3, load8(0xFFFFFFFF2F12FD84ull)); check("kernel-half address", EXCEPTION_ACCESS_VIOLATION, 1, 0xFFFFFFFF2F12FD84ull);
    RUN(3, load8(0xF6A489246888600Bull)); check("non-canonical address", EXCEPTION_ACCESS_VIOLATION, 1, ~(ULONG_PTR)0);
    RUN(3, load8(tagged));                check("non-canonical, low bits mapped", EXCEPTION_ACCESS_VIOLATION, 1, ~(ULONG_PTR)0);
    RUN(2, do_ud2());                     check("ud2", EXCEPTION_ILLEGAL_INSTRUCTION, 0, 0);
    RUN(6, do_evex());                    check("AVX512-BF16 (not in CPUID)", EXCEPTION_ILLEGAL_INSTRUCTION, 0, 0);
    RUN(3, do_serialize());               check("SERIALIZE (not in CPUID)", EXCEPTION_ILLEGAL_INSTRUCTION, 0, 0);
    RUN(1, do_hlt());                     check("hlt (privileged)", EXCEPTION_PRIV_INSTRUCTION, 0, 0);
    RUN(1, do_in());                      check("in al,dx (privileged)", EXCEPTION_PRIV_INSTRUCTION, 0, 0);
    fprintf(out, "%d mismatches\n", bad);
    fclose(out);
    return bad;
}
