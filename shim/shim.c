/* GameSpark shim: caches Win32 calls that are cheap on Windows but slow under Wine + FEX, for games that poll them
 * from their main loop. Loaded as a proxy for a DLL the game imports (shim/<name>.def lists that DLL's exports as
 * forwarders), so no game or Proton file is changed: system/shim.sh install copies it next to the game's exe and
 * profiles/launch/<appid>.env sets WINEDLLOVERRIDES=<name>=n,b.
 *
 * Cached: wininet!InternetGetConnectedState. Wine answers it by building the full adapter list twice, reading
 * /proc/net/dev once per interface it has ever seen (nsiproxy never forgets one, so container churn grows the list;
 * shim/igcs_cost.c measures it). The Witcher 3 calls it about 10 times a second on its main thread: a ~35 ms stall
 * every ~100 ms on the GB10.
 * Build: make shim (x86_64-w64-mingw32-gcc). Self-check: none needed beyond the frame-time run that measures it. */
#include <windows.h>
#include <psapi.h>
#include <string.h>

#define TTL_MS 2000   /* how stale "connected?" may be; a cable pull or Wi-Fi drop shows up within this */

static BOOL (WINAPI *real_igcs)(LPDWORD, DWORD);
static volatile ULONGLONG cached_at;
static volatile LONG64 cached;   /* bit 62: valid, bit 32: return value, low 32 bits: flags */

static BOOL WINAPI cached_igcs(LPDWORD flags, DWORD reserved)
{
    ULONGLONG now = GetTickCount64();
    LONG64 c = cached;
    if (!c || now - cached_at >= TTL_MS)
    {
        DWORD f = 0;
        BOOL r = real_igcs(&f, reserved);
        c = (1LL << 62) | ((LONG64)(r != 0) << 32) | f;
        cached = c;      /* ponytail: two threads may both refresh at expiry; the answers are equivalent */
        cached_at = now;
    }
    if (flags) *flags = (DWORD)c;
    return (BOOL)((c >> 32) & 1);
}

/* Point every import of wininet!InternetGetConnectedState in module m at the cache. */
static void hook_module(HMODULE m)
{
    BYTE *base = (BYTE *)m;
    IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)(base + ((IMAGE_DOS_HEADER *)base)->e_lfanew);
    IMAGE_DATA_DIRECTORY dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    IMAGE_IMPORT_DESCRIPTOR *d;
    if (!dir.VirtualAddress) return;
    for (d = (IMAGE_IMPORT_DESCRIPTOR *)(base + dir.VirtualAddress); d->Name; d++)
    {
        IMAGE_THUNK_DATA *names, *iat;
        if (lstrcmpiA((char *)base + d->Name, "wininet.dll") || !d->OriginalFirstThunk) continue;  /* names needed */
        names = (IMAGE_THUNK_DATA *)(base + d->OriginalFirstThunk);
        iat = (IMAGE_THUNK_DATA *)(base + d->FirstThunk);
        for (; names->u1.AddressOfData; names++, iat++)
        {
            DWORD old;
            if (IMAGE_SNAP_BY_ORDINAL(names->u1.Ordinal)) continue;
            if (strcmp((char *)((IMAGE_IMPORT_BY_NAME *)(base + names->u1.AddressOfData))->Name, "InternetGetConnectedState")) continue;
            if (!VirtualProtect(&iat->u1.Function, sizeof(void *), PAGE_READWRITE, &old)) continue;
            if (!real_igcs) real_igcs = (void *)iat->u1.Function;
            iat->u1.Function = (ULONG_PTR)cached_igcs;
            VirtualProtect(&iat->u1.Function, sizeof(void *), old, &old);
            OutputDebugStringA("gamespark-shim: caching InternetGetConnectedState\n");
        }
    }
}

BOOL WINAPI DllMain(HINSTANCE self, DWORD reason, void *reserved)
{
    HMODULE mods[512];
    DWORD bytes, i;
    if (reason != DLL_PROCESS_ATTACH) return TRUE;
    (void)reserved;
    DisableThreadLibraryCalls(self);
    /* The loader has resolved the static imports of everything loaded so far (the game and its own DLLs) before
     * running any DllMain. ponytail: DLLs loaded later keep the uncached call; hook LoadLibrary if one polls. */
    if (K32EnumProcessModules(GetCurrentProcess(), mods, sizeof(mods), &bytes))
        for (i = 0; i < bytes / sizeof(HMODULE) && i < 512; i++) hook_module(mods[i]);
    return TRUE;
}
