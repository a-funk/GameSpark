// GPU memory bandwidth probe: device-to-device copy + read-only reduce + FP32 FMA throughput, timed with CUDA events.
#include <cstdio>
#include <cuda_runtime.h>
__global__ void readk(const float4* __restrict__ a, size_t n, float* out) {
  float4 s = make_float4(0,0,0,0);
  for (size_t i = blockIdx.x * (size_t)blockDim.x + threadIdx.x; i < n; i += (size_t)gridDim.x * blockDim.x) { float4 v = a[i]; s.x += v.x; s.y += v.y; s.z += v.z; s.w += v.w; }
  if (s.x + s.y + s.z + s.w == 12345.f) *out = s.x;  // keep the loads alive
}
__global__ void fmak(float* out, int iters) {
  float a = threadIdx.x * 1e-7f, b = 0.999f, c = 1e-6f, d = a + 1, e = a + 2, f = a + 3, g = a + 4;
  for (int i = 0; i < iters; i++) { a = a*b+c; d = d*b+c; e = e*b+c; f = f*b+c; g = g*b+c; a = a*b+c; d = d*b+c; e = e*b+c; }
  if (a + d + e + f + g == 12345.f) *out = a;
}
int main() {
  const size_t bytes = 4ull << 30, n4 = bytes / 16;  // 4 GiB, far beyond L2
  float *a, *b, *o; cudaMalloc(&a, bytes); cudaMalloc(&b, bytes); cudaMalloc(&o, 4); cudaMemset(a, 0, bytes);
  cudaEvent_t t0, t1; cudaEventCreate(&t0); cudaEventCreate(&t1); float ms; int sms; cudaDeviceGetAttribute(&sms, cudaDevAttrMultiProcessorCount, 0);
  double best_copy = 0, best_read = 0, best_fma = 0;
  for (int r = 0; r < 5; r++) {
    cudaEventRecord(t0); cudaMemcpy(b, a, bytes, cudaMemcpyDeviceToDevice); cudaEventRecord(t1); cudaEventSynchronize(t1); cudaEventElapsedTime(&ms, t0, t1);
    best_copy = fmax(best_copy, 2.0 * bytes / (ms / 1e3) / 1e9);  // read + write
    cudaEventRecord(t0); readk<<<sms * 16, 256>>>((float4*)a, n4, o); cudaEventRecord(t1); cudaEventSynchronize(t1); cudaEventElapsedTime(&ms, t0, t1);
    best_read = fmax(best_read, bytes / (ms / 1e3) / 1e9);
    const int iters = 4096; cudaEventRecord(t0); fmak<<<sms * 64, 256>>>(o, iters); cudaEventRecord(t1); cudaEventSynchronize(t1); cudaEventElapsedTime(&ms, t0, t1);
    best_fma = fmax(best_fma, 2.0 * 8 * iters * (double)sms * 64 * 256 / (ms / 1e3) / 1e12);
  }
  printf("{\"sms\": %d, \"copy_GBps\": %.1f, \"read_GBps\": %.1f, \"fp32_TFLOPS\": %.2f, \"err\": \"%s\"}\n", sms, best_copy, best_read, best_fma, cudaGetErrorString(cudaGetLastError()));
}
