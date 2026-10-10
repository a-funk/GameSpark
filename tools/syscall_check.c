/* Direct Windows syscall check, the way Denuvo does it (docs/FINDINGS.md, Galactic Racer): copy ntdll's NtClose stub
 * into executable memory and enter the copy at its `syscall` instruction. Windows (and Wine, when it can intercept
 * direct syscalls) returns STATUS_INVALID_HANDLE (0xC0000008) for a bad handle. Wine returns from an intercepted
 * syscall to SIGSYS-RIP + 0xb, i.e. the `ret` after the dispatcher call in the stub, so the copy keeps that layout.
 * Needs Proton's Wine (it traps direct syscalls with seccomp; upstream Wine 11.5+ uses syscall user dispatch, which
 * arm64 kernels lack). Stock FEX 2610: the syscall runs as Linux syscall 15 (rt_sigreturn) and the program crashes;
 * with FEX_NEEDSSECCOMP=1 it loops; the patched FEX (system/fex-patched.sh) prints "ok" twice. The second line
 * repeats the call 30,000 times on a new thread: the first patched build leaked ~750 bytes of host stack per trapped
 * syscall, so a thread hung or died after ~11,000 (Galactic Racer's Denuvo threads got there in minutes).
 * Build: x86_64-w64-mingw32-gcc -O2 -mwindows -o syscall_check.exe tools/syscall_check.c */
#include <windows.h>
#include <stdio.h>
#include <string.h>

static BYTE *stub;   /* the copy's syscall instruction */
static DWORD stub_nr;

static ULONG_PTR call_syscall_at(void *target, DWORD nr, ULONG_PTR a1)
{
    ULONG_PTR ret;
    __asm__ volatile("mov %%rcx, %%r10\n\tcall *%[t]"
                     : "=a"(ret) : "a"((ULONG_PTR)nr), "c"(a1), [t] "r"(target)
                     : "r10", "r11", "rdx", "r8", "r9", "memory");
    return ret;
}

static DWORD WINAPI repeat(void *done)
{
    while (*(long *)done < 30000 && call_syscall_at(stub, stub_nr, 0x1234) == 0xC0000008) ++*(long *)done;
    return 0;
}

int main(int argc, char **argv)
{
    FILE *out = argc > 1 ? fopen(argv[1], "w") : stdout;
    long done = 0;
    int ok = 0;
    const BYTE *p = (const BYTE *)GetProcAddress(GetModuleHandleA("ntdll.dll"), "NtClose");
    LONG (WINAPI *pNtClose)(HANDLE) = (void *)p;
    BYTE *copy = VirtualAlloc(NULL, 4096, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    DWORD nr = 0xffffffff;
    int i, sc = -1;
    if (!out) return 2;   /* 2: could not open the output file, not a test failure */
    for (i = 0; p && i < 24; i++)
        if (p[i] == 0xb8) { nr = *(const DWORD *)(p + i + 1); break; }   /* mov eax, imm32 */
    for (i = 0; p && i < 40; i++)
        if (p[i] == 0x0f && p[i + 1] == 0x05) { sc = i; break; }        /* syscall */
    fprintf(out, "NtClose stub:");
    for (i = 0; p && i < 40; i++) fprintf(out, " %02x", p[i]);
    fprintf(out, "\nsyscall number %#lx at stub offset %#x\n", nr, sc);
    fprintf(out, "via ntdll:          %#llx\n", (unsigned long long)(ULONG)pNtClose((HANDLE)0x1234));
    fflush(out);
    if (nr != 0xffffffff && sc >= 0 && copy) {
        memcpy(copy, p, 64);
        ULONG_PTR r = call_syscall_at(copy + sc, nr, 0x1234);
        HANDLE t;
        fprintf(out, "stub-copy syscall:  %#llx  %s\n", (unsigned long long)r,
                r == 0xC0000008 ? "ok (intercepted by Wine)" : "WRONG");
        fflush(out);
        stub = copy + sc;
        stub_nr = nr;
        if (r == 0xC0000008 && (t = CreateThread(NULL, 0, repeat, &done, 0, NULL))) WaitForSingleObject(t, INFINITE);
        fprintf(out, "repeated on a new thread: %ld of 30000  %s\n", done, done == 30000 ? "ok" : "WRONG");
        ok = r == 0xC0000008 && done == 30000;
    }
    fclose(out);
    return ok ? 0 : 1;
}
