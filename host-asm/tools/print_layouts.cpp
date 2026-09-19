// Emits ground truth for the asm host: exact IID bytes, struct layouts and enum values.
// Compile with cl.exe from the VS BuildTools environment (see build.ps1 vcvars64 path).
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <cstdio>
#include <cstddef>

static void uuid_bytes(const char* name, REFGUID g) {
    const unsigned char* p = (const unsigned char*)&g;
    char buf[64];
    int o = 0;
    for (int i = 0; i < 16; ++i) o += sprintf_s(buf + o, sizeof(buf) - o, "%s%02Xh", i ? "," : "", p[i]);
    printf("%-26s db %s\n", name, buf);
}

#define OFF(T, f) printf("  %-34s %3zu\n", #f, offsetof(T, f))

int main() {
    printf("=== IID bytes for MASM ===\n");
    uuid_bytes("IDXGIFactory1", __uuidof(IDXGIFactory1));
    uuid_bytes("IDXGIAdapter1", __uuidof(IDXGIAdapter1));
    uuid_bytes("IDXGIOutput1", __uuidof(IDXGIOutput1));
    uuid_bytes("IDXGIOutputDuplication", __uuidof(IDXGIOutputDuplication));
    uuid_bytes("IDXGIDevice", __uuidof(IDXGIDevice));
    uuid_bytes("IDXGIResource", __uuidof(IDXGIResource));
    uuid_bytes("ID3D11Device", __uuidof(ID3D11Device));
    uuid_bytes("ID3D11DeviceContext", __uuidof(ID3D11DeviceContext));
    uuid_bytes("ID3D11Texture2D", __uuidof(ID3D11Texture2D));
    uuid_bytes("ID3D11VideoDevice", __uuidof(ID3D11VideoDevice));
    uuid_bytes("ID3D11VideoContext", __uuidof(ID3D11VideoContext));

    printf("\n=== D3D11_VIDEO_PROCESSOR_CONTENT_DESC (size %zu) ===\n", sizeof(D3D11_VIDEO_PROCESSOR_CONTENT_DESC));
    OFF(D3D11_VIDEO_PROCESSOR_CONTENT_DESC, InputFrameFormat);
    OFF(D3D11_VIDEO_PROCESSOR_CONTENT_DESC, InputFrameRate);
    OFF(D3D11_VIDEO_PROCESSOR_CONTENT_DESC, InputWidth);
    OFF(D3D11_VIDEO_PROCESSOR_CONTENT_DESC, InputHeight);
    OFF(D3D11_VIDEO_PROCESSOR_CONTENT_DESC, OutputFrameRate);
    OFF(D3D11_VIDEO_PROCESSOR_CONTENT_DESC, OutputWidth);
    OFF(D3D11_VIDEO_PROCESSOR_CONTENT_DESC, OutputHeight);
    OFF(D3D11_VIDEO_PROCESSOR_CONTENT_DESC, Usage);

    printf("\n=== D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC (size %zu) ===\n", sizeof(D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC));
    OFF(D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC, FourCC);
    OFF(D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC, ViewDimension);

    printf("\n=== D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC (size %zu) ===\n", sizeof(D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC));
    OFF(D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC, ViewDimension);

    printf("\n=== D3D11_VIDEO_PROCESSOR_STREAM (size %zu) ===\n", sizeof(D3D11_VIDEO_PROCESSOR_STREAM));
    OFF(D3D11_VIDEO_PROCESSOR_STREAM, Enable);
    OFF(D3D11_VIDEO_PROCESSOR_STREAM, OutputIndex);
    OFF(D3D11_VIDEO_PROCESSOR_STREAM, InputFrameOrField);
    OFF(D3D11_VIDEO_PROCESSOR_STREAM, PastFrames);
    OFF(D3D11_VIDEO_PROCESSOR_STREAM, FutureFrames);
    OFF(D3D11_VIDEO_PROCESSOR_STREAM, ppPastSurfaces);
    OFF(D3D11_VIDEO_PROCESSOR_STREAM, pInputSurface);
    OFF(D3D11_VIDEO_PROCESSOR_STREAM, ppFutureSurfaces);
    OFF(D3D11_VIDEO_PROCESSOR_STREAM, ppPastSurfacesRight);
    OFF(D3D11_VIDEO_PROCESSOR_STREAM, pInputSurfaceRight);
    OFF(D3D11_VIDEO_PROCESSOR_STREAM, ppFutureSurfacesRight);

    printf("\n=== D3D11_VIDEO_PROCESSOR_COLOR_SPACE (size %zu) ===\n", sizeof(D3D11_VIDEO_PROCESSOR_COLOR_SPACE));

    printf("\n=== values ===\n");
    printf("  D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE = %d\n", (int)D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE);
    printf("  D3D11_VIDEO_USAGE_OPTIMAL_SPEED      = %d\n", (int)D3D11_VIDEO_USAGE_OPTIMAL_SPEED);
    printf("  D3D11_VPIV_DIMENSION_TEXTURE2D       = %d\n", (int)D3D11_VPIV_DIMENSION_TEXTURE2D);
    printf("  D3D11_VPOV_DIMENSION_TEXTURE2D       = %d\n", (int)D3D11_VPOV_DIMENSION_TEXTURE2D);
    printf("  D3D11_BIND_RENDER_TARGET             = 0x%X\n", (unsigned)D3D11_BIND_RENDER_TARGET);
    printf("  D3D11_USAGE_DEFAULT                  = %d\n", (int)D3D11_USAGE_DEFAULT);
    printf("  D3D11_USAGE_STAGING                  = %d\n", (int)D3D11_USAGE_STAGING);
    printf("  D3D11_CPU_ACCESS_READ                = 0x%X\n", (unsigned)D3D11_CPU_ACCESS_READ);
    printf("  D3D11_MAP_READ                       = %d\n", (int)D3D11_MAP_READ);
    printf("  DXGI_FORMAT_NV12                     = %d\n", (int)DXGI_FORMAT_NV12);
    printf("  DXGI_FORMAT_B8G8R8A8_UNORM           = %d\n", (int)DXGI_FORMAT_B8G8R8A8_UNORM);
    printf("  DXGI_FORMAT_R8G8B8A8_UNORM           = %d\n", (int)DXGI_FORMAT_R8G8B8A8_UNORM);
    return 0;
}
