// GameSpark repro: cross-API shared resources between the D3D12 renderer and the D3D11
// Media-Foundation decoder (Crimson Desert's intro video never finishes on this stack:
// docs/FINDINGS.md "Crimson Desert"). Same process, same order the game uses:
// D3D12 device first (VKD3D-Proton), then D3D11 (DXVK), then hand resources across.
//
// Build: x86_64-w64-mingw32-g++ -O2 -static -o tests/sharedtex/sharedtex.exe tests/sharedtex/sharedtex.cpp \
//          -ld3d12 -ld3d11 -ldxgi -ldxguid
// Run:   proton run sharedtex.exe report.txt   (in a throwaway prefix; report.txt = the last run's result)
//
// mingw-w64 v11 notes: CreateSharedHandle's riid slot is typed const WCHAR* there (wrong
// prototype, same ABI: a GUID >8 bytes and a pointer both pass in one slot by value);
// D3D11_RESOURCE_MISC_SHARED_NTHANDLE spelling; D3D_FEATURE_LEVEL for the 11 level out-param.
//
// Tests, each printing OK/FAIL so a hang is distinguishable from an error:
//   E  D3D12 -> D3D12  (vkd3d self round-trip: CreateSharedHandle/OpenSharedHandle)
//   F  D3D11 -> D3D11  (DXVK self round-trip: GetSharedHandle/OpenSharedResource1)
//   A  D3D11 -> D3D12  (game's direction: NT-handle texture, OpenSharedHandle)
//   B  D3D12 -> D3D11  (CreateSharedHandle, OpenSharedResource1)
//   C  D3D12 -> D3D11  (fence: CreateSharedHandle, OpenSharedFence)
#include <windows.h>
#include <d3d11.h>
#include <d3d11_2.h>
#include <d3d11_4.h>
#include <d3d12.h>
#include <dxgi1_6.h>
#include <stdio.h>

static ID3D12Device *d12 = nullptr;
static ID3D11Device *d11 = nullptr;
static ID3D11Device2 *d11b = nullptr;   // OpenSharedResource1
static ID3D11Device5 *d11f = nullptr;   // OpenSharedFence
static ID3D11DeviceContext *ctx = nullptr;

static long fails = 0;
static const IID nullGuid = {0, 0, 0, {0, 0, 0, 0, 0, 0, 0, 0}};

static void note(const char *what, HRESULT hr) {
  fflush(stdout);
  if (FAILED(hr)) { fails++; printf("FAIL  %-44s hr=0x%08lx\n", what, (unsigned long)hr); }
  else           {         printf("ok    %-44s\n", what); }
  fflush(stdout);
}

static ID3D11Texture2D *make_d11_tex(UINT misc) {
  D3D11_TEXTURE2D_DESC td{};
  td.Width = 1920; td.Height = 1080; td.MipLevels = 1; td.ArraySize = 1;
  td.Format = DXGI_FORMAT_B8G8R8A8_UNORM; td.SampleDesc.Count = 1;
  td.Usage = D3D11_USAGE_DEFAULT;
  td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  td.MiscFlags = misc;   // SHARED | SHARED_NTHANDLE for the cross-API tests
  ID3D11Texture2D *tex = nullptr;
  note("D3D11 CreateTexture2D", d11->CreateTexture2D(&td, nullptr, &tex));
  return tex;
}

static ID3D12Resource *make_d12_res(void) {
  D3D12_HEAP_PROPERTIES hp{}; hp.Type = D3D12_HEAP_TYPE_DEFAULT;
  D3D12_RESOURCE_DESC rd{};
  rd.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D; rd.Width = 1920; rd.Height = 1080;
  rd.DepthOrArraySize = 1; rd.MipLevels = 1; rd.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  rd.SampleDesc.Count = 1; rd.Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN;
  rd.Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
  ID3D12Resource *res = nullptr;
  HRESULT hr = d12->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_SHARED, &rd,
                                            D3D12_RESOURCE_STATE_RENDER_TARGET, nullptr,
                                            IID_PPV_ARGS(&res));
  note("D3D12 CreateCommittedResource", hr);
  return res;
}

// mingw v11 declares CreateSharedHandle's 4th slot as const WCHAR*; the real call passes a
// REFIID, which under the x64 ABI is a pointer like this cast produces.
static HRESULT d12_share(ID3D12DeviceChild *obj, HANDLE *out) {
  return d12->CreateSharedHandle(obj, nullptr, 0, (const WCHAR *)&nullGuid, (void **)out);
}

int main(int argc, char **argv) {
  // argv[1]: optional file for the report (the console is not reliably wired through proton run)
  if (argc > 1 && !freopen(argv[1], "w", stdout)) printf("cannot open report file %s\n", argv[1]);
  printf("sharedtex repro: cross-API D3D11<->D3D12 shared resources\n"); fflush(stdout);
  HRESULT hr;

  // ---- devices, in the game's order: renderer (D3D12) first, then MF (D3D11)
  hr = D3D12CreateDevice(nullptr, D3D_FEATURE_LEVEL_12_0, IID_PPV_ARGS(&d12));
  if (FAILED(hr)) { note("D3D12CreateDevice", hr); return 1; }
  printf("ok    D3D12CreateDevice\n"); fflush(stdout);

  D3D_FEATURE_LEVEL fl;
  hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                         D3D11_CREATE_DEVICE_VIDEO_SUPPORT | D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                         nullptr, 0, D3D11_SDK_VERSION, &d11, &fl, &ctx);
  if (FAILED(hr)) { note("D3D11CreateDevice", hr); return 1; }
  printf("ok    D3D11CreateDevice (feature level 0x%x)\n", (unsigned)fl); fflush(stdout);
  note("QI ID3D11Device2", d11->QueryInterface(IID_PPV_ARGS(&d11b)));
  note("QI ID3D11Device5", d11->QueryInterface(IID_PPV_ARGS(&d11f)));

  // ---- E: vkd3d self round-trip (pure vkd3d handle plumbing)
  {
    ID3D12Resource *res = make_d12_res();
    if (res) {
      HANDLE h = nullptr;
      note("E D3D12 CreateSharedHandle", d12_share(res, &h));
      ID3D12Resource *back = nullptr;
      if (h) note("E D3D12 OpenSharedHandle  (self)", d12->OpenSharedHandle(h, IID_PPV_ARGS(&back)));
      if (h) CloseHandle(h);
      if (back) back->Release();
      res->Release();
    }
  }

  // ---- F: DXVK self round-trip (pure DXVK handle plumbing)
  {
    ID3D11Texture2D *tex = make_d11_tex(D3D11_RESOURCE_MISC_SHARED | D3D11_RESOURCE_MISC_SHARED_NTHANDLE);
    if (tex) {
      HANDLE h = nullptr;
      IDXGIResource *gi = nullptr;
      note("F QI IDXGIResource", tex->QueryInterface(IID_PPV_ARGS(&gi)));
      if (gi) { note("F D3D11 GetSharedHandle (self)", gi->GetSharedHandle((HANDLE *)&h)); gi->Release(); }
      ID3D11Texture2D *back = nullptr;
      if (h && d11b) note("F D3D11 OpenSharedResource1 (self)", d11b->OpenSharedResource1(h, IID_PPV_ARGS(&back)));
      if (h) CloseHandle(h);
      if (back) back->Release();
      tex->Release();
    }
  }

  // ---- A: D3D11 -> D3D12, the game's direction (MF decoder -> renderer), the RIGHT API:
  //         NTHANDLE textures export through IDXGIResource1::CreateSharedHandle; DXVK's
  //         GetSharedHandle rejects them by design (d3d11_resource.cpp).
  {
    ID3D11Texture2D *tex = make_d11_tex(D3D11_RESOURCE_MISC_SHARED | D3D11_RESOURCE_MISC_SHARED_NTHANDLE);
    if (tex) {
      HANDLE h = nullptr;
      IDXGIResource1 *gi1 = nullptr;
      if (SUCCEEDED(tex->QueryInterface(IID_PPV_ARGS(&gi1)))) {
        note("A D3D11 IDXGIResource1::CreateSharedHandle", gi1->CreateSharedHandle(nullptr, 0, nullptr, &h));
        gi1->Release();
      } else printf("FAIL  A no IDXGIResource1 on the texture\n");
      ID3D12Resource *res12 = nullptr;
      if (h) note("A D3D12 OpenSharedHandle  (from D3D11)", d12->OpenSharedHandle(h, IID_PPV_ARGS(&res12)));
      else printf("FAIL  A no shared handle to try\n");
      if (h) CloseHandle(h);
      if (res12) res12->Release();
      tex->Release();
    }
  }

  // ---- G: keyed-mutex handoff (legacy KMT handle via GetSharedHandle), common for MF video
  {
    ID3D11Texture2D *tex = make_d11_tex(D3D11_RESOURCE_MISC_SHARED | D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX);
    if (tex) {
      HANDLE h = nullptr;
      IDXGIResource *gi = nullptr;
      if (SUCCEEDED(tex->QueryInterface(IID_PPV_ARGS(&gi)))) {
        note("G D3D11 GetSharedHandle (KMT)", gi->GetSharedHandle((HANDLE *)&h));
        gi->Release();
      }
      ID3D12Resource *res12 = nullptr;
      if (h) note("G D3D12 OpenSharedHandle  (KMT)", d12->OpenSharedHandle(h, IID_PPV_ARGS(&res12)));
      else printf("FAIL  G no shared handle to try\n");
      if (h) CloseHandle(h);
      if (res12) res12->Release();
      tex->Release();
    }
  }

  // ---- H: NV12 decoder texture (the real intro-video payload), D3D11 -> D3D12
  {
    D3D11_TEXTURE2D_DESC td{};
    td.Width = 1920; td.Height = 1080; td.MipLevels = 1; td.ArraySize = 1;
    td.Format = DXGI_FORMAT_NV12; td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_DECODER | D3D11_BIND_SHADER_RESOURCE;
    td.MiscFlags = D3D11_RESOURCE_MISC_SHARED | D3D11_RESOURCE_MISC_SHARED_NTHANDLE;
    ID3D11Texture2D *tex = nullptr;
    note("H D3D11 CreateTexture2D (NV12 decoder)", d11->CreateTexture2D(&td, nullptr, &tex));
    if (tex) {
      HANDLE h = nullptr;
      IDXGIResource1 *gi1 = nullptr;
      if (SUCCEEDED(tex->QueryInterface(IID_PPV_ARGS(&gi1)))) {
        note("H D3D11 CreateSharedHandle (NV12)", gi1->CreateSharedHandle(nullptr, 0, nullptr, &h));
        gi1->Release();
      }
      ID3D12Resource *res12 = nullptr;
      if (h) note("H D3D12 OpenSharedHandle  (NV12)", d12->OpenSharedHandle(h, IID_PPV_ARGS(&res12)));
      if (h) CloseHandle(h);
      if (res12) res12->Release();
      tex->Release();
    }
  }

  // ---- I: NV12 the other way, D3D12 -> D3D11 import with DECODER bind
  {
    D3D12_HEAP_PROPERTIES hp{}; hp.Type = D3D12_HEAP_TYPE_DEFAULT;
    D3D12_RESOURCE_DESC rd{};
    rd.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D; rd.Width = 1920; rd.Height = 1080;
    rd.DepthOrArraySize = 1; rd.MipLevels = 1; rd.Format = DXGI_FORMAT_NV12;
    rd.SampleDesc.Count = 1; rd.Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN;
    rd.Flags = D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
    ID3D12Resource *res = nullptr;
    note("I D3D12 CreateCommittedResource (NV12)",
         d12->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_SHARED, &rd,
                                      D3D12_RESOURCE_STATE_COMMON, nullptr, IID_PPV_ARGS(&res)));
    if (res) {
      HANDLE h = nullptr;
      note("I D3D12 CreateSharedHandle (NV12)", d12_share(res, &h));
      ID3D11Texture2D *tex11 = nullptr;
      if (h && d11b) note("I D3D11 OpenSharedResource1 (NV12)", d11b->OpenSharedResource1(h, IID_PPV_ARGS(&tex11)));
      if (h) CloseHandle(h);
      if (tex11) tex11->Release();
      res->Release();
    }
  }

  // ---- B: D3D12 -> D3D11 (renderer -> decoder)
  {
    ID3D12Resource *res = make_d12_res();
    if (res) {
      HANDLE h = nullptr;
      note("B D3D12 CreateSharedHandle", d12_share(res, &h));
      ID3D11Texture2D *tex11 = nullptr;
      if (h && d11b) note("B D3D11 OpenSharedResource1 (from D3D12)", d11b->OpenSharedResource1(h, IID_PPV_ARGS(&tex11)));
      if (h) CloseHandle(h);
      if (tex11) tex11->Release();
      res->Release();
    }
  }

  // ---- C: D3D12 fence -> D3D11 (fences ride the same NT-handle path)
  {
    ID3D12Fence *f = nullptr;
    note("C D3D12 CreateFence", d12->CreateFence(0, D3D12_FENCE_FLAG_SHARED, IID_PPV_ARGS(&f)));
    if (f) {
      HANDLE h = nullptr;
      note("C D3D12 CreateSharedHandle (fence)", d12_share(f, &h));
      ID3D11Fence *f11 = nullptr;
      if (h && d11f) note("C D3D11 OpenSharedFence   (from D3D12)", d11f->OpenSharedFence(h, IID_PPV_ARGS(&f11)));
      if (h) CloseHandle(h);
      if (f11) f11->Release();
      f->Release();
    }
  }

  printf("sharedtex repro done: %ld failure(s)\n", fails);
  return fails != 0;
}
