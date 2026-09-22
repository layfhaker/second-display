// SecondDisplay host, HolyC port - DXGI Desktop Duplication Screen Capture (100% Pure HolyC).
//
// Hardware-accelerated GPU desktop capture using DirectX 11 / DXGI Desktop Duplication.
// Directly captures composited GPU frames from virtual display (\\.\\DISPLAY5 / DISPLAY6)
// and converts to NV12 using BT.601 integer algorithm.

#define STREAM_W        1920
#define STREAM_H        1280
#define STREAM_REFRESH  60
#define FRAME_NV12      3686400         // STREAM_W * STREAM_H * 3 / 2

I32 g_cap_w = STREAM_W;
I32 g_cap_h = STREAM_H;

U8 *frame_nv12 = NULL;
Bool has_valid_frame = FALSE;

ID3D11Device           *pD3DDevice   = NULL;
ID3D11DeviceContext    *pD3DContext  = NULL;
IDXGIOutputDuplication *pDuplication = NULL;
ID3D11Texture2D        *pStagingTex  = NULL;
IDXGIOutput1           *pDxgiOutput1 = NULL;

I32 originX = 1920;
I32 originY = 0;
I32 capW = 1920;
I32 capH = 1280;

Bool CaptureScreen();

U8 ClipU8(I64 v)
{
    if (v < 0)   return 0;
    if (v > 255) return 255;
    return (U8)v;
}

// One BGRA source row -> one NV12 luma row.
U0 BgraRowToY(U8 *src, U8 *dst, I64 pixels)
{
    I64 i;
    for (i = 0; i < pixels; i++) {
        I64 b = src[i * 4 + 0];
        I64 g = src[i * 4 + 1];
        I64 r = src[i * 4 + 2];
        dst[i] = ClipU8(((66 * r + 129 * g + 25 * b + 128) >> 8) + 16);
    }
}

// Two BGRA source rows -> one interleaved Cb/Cr chroma row.
U0 BgraRowsToUv(U8 *row0, U8 *row1, U8 *dst, I64 pixels)
{
    I64 x;
    for (x = 0; x < pixels; x += 2) {
        I64 b = row0[x * 4 + 0] + row0[(x + 1) * 4 + 0] + row1[x * 4 + 0] + row1[(x + 1) * 4 + 0];
        I64 g = row0[x * 4 + 1] + row0[(x + 1) * 4 + 1] + row1[x * 4 + 1] + row1[(x + 1) * 4 + 1];
        I64 r = row0[x * 4 + 2] + row0[(x + 1) * 4 + 2] + row1[x * 4 + 2] + row1[(x + 1) * 4 + 2];
        b >>= 2; g >>= 2; r >>= 2;
        dst[x]     = ClipU8((((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128));
        dst[x + 1] = ClipU8(((112 * r - 94 * g - 18 * b + 128) >> 8) + 128);
    }
}

// Fill frame_nv12 from a BGRA buffer of width x height with the given source row pitch.
U0 ConvertBgraToNv12(U8 *bgra, I64 pitch, I64 width, I64 height)
{
    U8 *luma   = frame_nv12;
    U8 *chroma = frame_nv12 + width * height;
    I64 y;
    for (y = 0; y < height; y++)
        BgraRowToY(bgra + y * pitch, luma + y * width, width);
    for (y = 0; y < height; y += 2)
        BgraRowsToUv(bgra + y * pitch, bgra + (y + 1) * pitch, chroma + (y / 2) * width, width);
}

// Initialise capture via DXGI Desktop Duplication
Bool CaptureInit()
{
    // Attach calling thread to interactive "Default" desktop to permit DXGI duplication
    HDESK hDefaultDesk = OpenDesktopA("Default", 0, FALSE, DESKTOP_READOBJECTS | DESKTOP_WRITEOBJECTS | DESKTOP_SWITCHDESKTOP);
    if (hDefaultDesk) {
        SetThreadDesktop(hDefaultDesk);
    }

    if (!frame_nv12) {
        frame_nv12 = MAlloc(FRAME_NV12);
        if (!frame_nv12) return FALSE;
        MemSet(frame_nv12, 16, STREAM_W * STREAM_H);
        MemSet(frame_nv12 + STREAM_W * STREAM_H, 128, STREAM_W * STREAM_H / 2);
    }
    has_valid_frame = FALSE;

    IDXGIFactory1 *pFactory = NULL;
    HRESULT hr = CreateDXGIFactory1(__uuidof(IDXGIFactory1), (void**)&pFactory);
    if (FAILED(hr) || !pFactory) {
        "Failed to create DXGI Factory 1 (hr=0x%08X)\n", hr;
        return FALSE;
    }

    IDXGIAdapter1 *pChosenAdapter = NULL;
    IDXGIOutput1 *pChosenOutput = NULL;

    // Dynamically detect virtual display name via PnP monitor ID (MTT / Virtual)
    char targetName[32] = "";
    DISPLAY_DEVICEA dd;
    DISPLAY_DEVICEA monDd;
    int devIdx = 0;
    MemSet(&dd, 0, sizeof(dd));
    dd.cb = sizeof(dd);
    while (EnumDisplayDevicesA(NULL, devIdx, &dd, 0)) {
        MemSet(&monDd, 0, sizeof(monDd));
        monDd.cb = sizeof(monDd);
        if (EnumDisplayDevicesA(dd.DeviceName, 0, &monDd, 0)) {
            if (strstr(monDd.DeviceID, "MTT") || strstr(monDd.DeviceString, "Virtual")) {
                strcpy(targetName, dd.DeviceName);
                break;
            }
        }
        MemSet(&dd, 0, sizeof(dd));
        dd.cb = sizeof(dd);
        devIdx++;
    }

    DEVMODEA dm;
    MemSet(&dm, 0, sizeof(dm));
    dm.dmSize = sizeof(dm);
    if (targetName[0] == '\0' || !EnumDisplaySettingsA(targetName, ENUM_CURRENT_SETTINGS, &dm)) {
        strcpy(targetName, "\\\\.\\DISPLAY5");
        if (!EnumDisplaySettingsA(targetName, ENUM_CURRENT_SETTINGS, &dm)) {
            strcpy(targetName, "\\\\.\\DISPLAY6");
            EnumDisplaySettingsA(targetName, ENUM_CURRENT_SETTINGS, &dm);
        }
    }

    originX = dm.dmPosition.x;
    originY = dm.dmPosition.y;
    capW = dm.dmPelsWidth ? dm.dmPelsWidth : STREAM_W;
    capH = dm.dmPelsHeight ? dm.dmPelsHeight : STREAM_H;
    g_cap_w = capW;
    g_cap_h = capH;

    WCHAR wTargetName[32];
    MultiByteToWideChar(CP_ACP, 0, targetName, -1, wTargetName, 32);

    UINT ai = 0;
    IDXGIAdapter1 *pAdapter = NULL;
    while (pFactory->EnumAdapters1(ai, &pAdapter) == S_OK) {
        UINT oi = 0;
        IDXGIOutput *pOutput = NULL;
        while (pAdapter->EnumOutputs(oi, &pOutput) == S_OK) {
            DXGI_OUTPUT_DESC desc;
            pOutput->GetDesc(&desc);
            if (wcscmp(desc.DeviceName, wTargetName) == 0) {
                hr = pOutput->QueryInterface(__uuidof(IDXGIOutput1), (void**)&pChosenOutput);
                pOutput->Release();
                if (SUCCEEDED(hr)) {
                    pChosenAdapter = pAdapter;
                    break;
                }
            }
            pOutput->Release();
            oi++;
        }
        if (pChosenOutput) break;
        pAdapter->Release();
        ai++;
    }
    pFactory->Release();

    if (!pChosenAdapter || !pChosenOutput) {
        "Target DXGI output '%s' not found!\n", targetName;
        return FALSE;
    }

    // Create Direct3D 11 device on chosen adapter
    D3D_FEATURE_LEVEL levels[3] = {
        D3D_FEATURE_LEVEL_11_1,
        D3D_FEATURE_LEVEL_11_0,
        D3D_FEATURE_LEVEL_10_1
    };
    D3D_FEATURE_LEVEL featureLevel;
    hr = D3D11CreateDevice(
        (IDXGIAdapter*)pChosenAdapter,
        D3D_DRIVER_TYPE_UNKNOWN,
        NULL,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        levels,
        3,
        D3D11_SDK_VERSION,
        &pD3DDevice,
        &featureLevel,
        &pD3DContext
    );
    pChosenAdapter->Release();

    if (FAILED(hr) || !pD3DDevice || !pD3DContext) {
        "D3D11CreateDevice failed (hr=0x%08X)\n", hr;
        pChosenOutput->Release();
        return FALSE;
    }

    pDxgiOutput1 = pChosenOutput;

    // Create desktop duplication
    hr = pDxgiOutput1->DuplicateOutput((IUnknown*)pD3DDevice, &pDuplication);
    if (FAILED(hr) || !pDuplication) {
        "DXGI DuplicateOutput failed (hr=0x%08X)\n", hr;
        return FALSE;
    }

    // Create staging texture for CPU readback
    D3D11_TEXTURE2D_DESC sDesc;
    MemSet(&sDesc, 0, sizeof(sDesc));
    sDesc.Width = STREAM_W;
    sDesc.Height = STREAM_H;
    sDesc.MipLevels = 1;
    sDesc.ArraySize = 1;
    sDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    sDesc.SampleDesc.Count = 1;
    sDesc.SampleDesc.Quality = 0;
    sDesc.Usage = D3D11_USAGE_STAGING;
    sDesc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;

    hr = pD3DDevice->CreateTexture2D(&sDesc, NULL, &pStagingTex);
    if (FAILED(hr) || !pStagingTex) {
        "Failed to create D3D11 staging texture (hr=0x%08X)\n", hr;
        return FALSE;
    }

    // Trigger initial frame capture
    I64 warmup;
    for (warmup = 0; warmup < 10 && !has_valid_frame; warmup++) {
        CaptureScreen();
        if (!has_valid_frame) Sleep(30);
    }

    "DXGI Desktop Duplication initialized: %s (%dx%d at %d,%d, ready=%d)\n", targetName, STREAM_W, STREAM_H, originX, originY, has_valid_frame;
    return TRUE;
}

U0 CaptureCleanup()
{
    if (pStagingTex) {
        pStagingTex->Release();
        pStagingTex = NULL;
    }
    if (pDuplication) {
        pDuplication->Release();
        pDuplication = NULL;
    }
    if (pDxgiOutput1) {
        pDxgiOutput1->Release();
        pDxgiOutput1 = NULL;
    }
    if (pD3DContext) {
        pD3DContext->Release();
        pD3DContext = NULL;
    }
    if (pD3DDevice) {
        pD3DDevice->Release();
        pD3DDevice = NULL;
    }
    if (frame_nv12) {
        Free(frame_nv12);
        frame_nv12 = NULL;
    }
    has_valid_frame = FALSE;
}

// Grab one frame via DXGI Desktop Duplication and convert to NV12
Bool CaptureScreen()
{
    if (!pDuplication || !pD3DContext || !pStagingTex) return FALSE;

    DXGI_OUTDUPL_FRAME_INFO frameInfo;
    IDXGIResource *pDesktopResource = NULL;
    HRESULT hr = pDuplication->AcquireNextFrame(10, &frameInfo, &pDesktopResource);

    if (hr == DXGI_ERROR_WAIT_TIMEOUT) {
        // Static desktop, nothing new: report no frame so the caller can sleep
        // instead of re-feeding a duplicate at full spin (that queued unbounded
        // inputs in the MFT -> GBs of commit + CPU saturation = lag).
        return FALSE;
    }

    if (hr == DXGI_ERROR_ACCESS_LOST) {
        // Reinitialize duplication on access loss (e.g. resolution change, mode switch)
        pDuplication->Release();
        pDuplication = NULL;
        if (pDxgiOutput1 && pD3DDevice) {
            pDxgiOutput1->DuplicateOutput((IUnknown*)pD3DDevice, &pDuplication);
        }
        return FALSE;
    }

    if (FAILED(hr) || !pDesktopResource) {
        return FALSE;
    }

    if (pDesktopResource) {
        ID3D11Texture2D *pFrameTex = NULL;
        hr = pDesktopResource->QueryInterface(__uuidof(ID3D11Texture2D), (void**)&pFrameTex);
        if (SUCCEEDED(hr) && pFrameTex) {
            // Skip duplicate presents: feeding the same composited frame again only
            // burns CPU in convert + queues junk in the encoder.
            if (frameInfo.LastPresentTime.QuadPart == 0) {
                pFrameTex->Release();
                pDesktopResource->Release();
                pDuplication->ReleaseFrame();
                return FALSE;
            }
            pD3DContext->CopyResource((ID3D11Resource*)pStagingTex, (ID3D11Resource*)pFrameTex);
            pFrameTex->Release();

            pDesktopResource->Release();
            pDuplication->ReleaseFrame();

            D3D11_MAPPED_SUBRESOURCE mapped;
            hr = pD3DContext->Map((ID3D11Resource*)pStagingTex, 0, D3D11_MAP_READ, 0, &mapped);
            if (SUCCEEDED(hr)) {
                ConvertBgraToNv12((U8*)mapped.pData, mapped.RowPitch, STREAM_W, STREAM_H);
                pD3DContext->Unmap((ID3D11Resource*)pStagingTex, 0);
                has_valid_frame = TRUE;
                return TRUE;
            }
            return TRUE;
        }
    }

    pDesktopResource->Release();
    pDuplication->ReleaseFrame();
    return TRUE;
}

Bool CaptureFrame()
{
    return CaptureScreen();
}
