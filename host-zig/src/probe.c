// Definitive vtable slot dumper for the SecondDisplay Zig host.
// Prints the actual slot index of every COM method we call, straight from
// the live objects, so the Zig constants can be verified against reality.
#define INITGUID
#define COBJMACROS
#define CINTERFACE
#include <windows.h>
#include <stdio.h>
#include <dxgi1_2.h>
#include <d3d11.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mftransform.h>

static void *slot_of(const void *vtbl, const void *fn, const char *name, int max) {
    const void **v = (const void **)vtbl;
    for (int i = 0; i < max; i++) {
        if (v[i] == fn) {
            printf("  %-40s slot=%3d off=%4d\n", name, i, i * 8);
            return (void *)(size_t)i;
        }
    }
    printf("  %-40s NOT FOUND\n", name);
    return NULL;
}

int main(void) {
    CoInitializeEx(NULL, COINIT_MULTITHREADED);

    IDXGIFactory1 *factory = NULL;
    HRESULT hr = CreateDXGIFactory1(&IID_IDXGIFactory1, (void **)&factory);
    printf("factory hr=%08lX p=%p\n", (unsigned long)hr, (void *)factory);
    if (!factory) return 1;

    printf("== IDXGIFactory1 ==\n");
    slot_of(factory->lpVtbl, (const void *)factory->lpVtbl->EnumAdapters, "EnumAdapters", 40);
    slot_of(factory->lpVtbl, (const void *)factory->lpVtbl->EnumAdapters1, "EnumAdapters1", 40);
    slot_of(factory->lpVtbl, (const void *)factory->lpVtbl->IsCurrent, "IsCurrent", 40);
    slot_of(factory->lpVtbl, (const void *)factory->lpVtbl->SetPrivateData, "SetPrivateData", 40);

    IDXGIAdapter *adapter = NULL;
    int adapterIdx = 0;
    while (IDXGIFactory_EnumAdapters(factory, adapterIdx, &adapter) == S_OK) {
        printf("== adapter[%d] p=%p ==\n", adapterIdx, (void *)adapter);
        slot_of(adapter->lpVtbl, (const void *)adapter->lpVtbl->EnumOutputs, "EnumOutputs", 40);
        IDXGIOutput *output = NULL;
        int oi = 0;
        while (IDXGIAdapter_EnumOutputs(adapter, oi, &output) == S_OK) {
            DXGI_OUTPUT_DESC od = {0};
            IDXGIOutput_GetDesc(output, &od);
            wchar_t wnm[32];
            memcpy(wnm, od.DeviceName, sizeof(wnm));
            wnm[31] = 0;
            printf("  out[%d] name='%ls' attached=%ld rect=%ld,%ld %ldx%ld\n", oi, wnm,
                   (long)od.AttachedToDesktop,
                   od.DesktopCoordinates.left, od.DesktopCoordinates.top,
                   od.DesktopCoordinates.right - od.DesktopCoordinates.left,
                   od.DesktopCoordinates.bottom - od.DesktopCoordinates.top);
            if (adapterIdx == 0 && oi == 0) {
                slot_of(output->lpVtbl, (const void *)output->lpVtbl->GetDesc, "Output.GetDesc", 40);
                IDXGIOutput1 *out1 = NULL;
                HRESULT qhr = IDXGIOutput_QueryInterface(output, &IID_IDXGIOutput1, (void **)&out1);
                printf("QI Output1 hr=%08lX p=%p\n", (unsigned long)qhr, (void *)out1);
                if (out1) {
                    printf("== IDXGIOutput1 ==\n");
                    slot_of(out1->lpVtbl, (const void *)out1->lpVtbl->DuplicateOutput, "Output1.DuplicateOutput", 40);
                    IDXGIOutput1_Release(out1);
                }
            }
            IDXGIOutput_Release(output);
            output = NULL;
            oi++;
        }
        if (adapterIdx == 0) {
            // D3D11 device on adapter0, then dump device/context slots.
            ID3D11Device *dev = NULL;
            ID3D11DeviceContext *ctx = NULL;
            D3D_FEATURE_LEVEL fl;
            D3D_FEATURE_LEVEL levels[3] = { D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1 };
            HRESULT hr2 = D3D11CreateDevice((IDXGIAdapter *)adapter, D3D_DRIVER_TYPE_UNKNOWN, NULL,
                                       D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels, 3, D3D11_SDK_VERSION,
                                       &dev, &fl, &ctx);
            printf("D3D11CreateDevice hr=%08lX p=%p\n", (unsigned long)hr2, (void *)dev);
            if (dev) {
                printf("== ID3D11Device ==\n");
                printf("dev.lpVtbl=%p ctx.lpVtbl=%p\n", (void *)dev->lpVtbl, (void *)ctx->lpVtbl);
                slot_of(dev->lpVtbl, (const void *)dev->lpVtbl->CreateTexture2D, "Device.CreateTexture2D", 64);
                printf("== ID3D11DeviceContext ==\n");
                slot_of(ctx->lpVtbl, (const void *)ctx->lpVtbl->Map, "Context.Map", 200);
                slot_of(ctx->lpVtbl, (const void *)ctx->lpVtbl->Unmap, "Context.Unmap", 200);
                slot_of(ctx->lpVtbl, (const void *)ctx->lpVtbl->CopyResource, "Context.CopyResource", 200);

                printf("sizeof(D3D11_TEXTURE2D_DESC)=%u\n", (unsigned)sizeof(D3D11_TEXTURE2D_DESC));
                D3D11_TEXTURE2D_DESC sd;
                ZeroMemory(&sd, sizeof(sd));
                sd.Width = 1920; sd.Height = 1280; sd.MipLevels = 1; sd.ArraySize = 1;
                sd.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
                sd.SampleDesc.Count = 1; sd.SampleDesc.Quality = 0;
                sd.Usage = D3D11_USAGE_STAGING;
                sd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
                ID3D11Texture2D *stg = NULL;
                HRESULT shr = ID3D11Device_CreateTexture2D(dev, &sd, NULL, &stg);
                printf("C staging CreateTexture2D hr=%08lX p=%p (format=%d usage=%d cpu=0x%X)\n",
                       (unsigned long)shr, (void *)stg, (int)sd.Format, (int)sd.Usage, sd.CPUAccessFlags);
                if (stg) ID3D11Texture2D_Release(stg);
                ID3D11Device_Release(dev);
                ID3D11DeviceContext_Release(ctx);
            }
        }
        IDXGIAdapter_Release(adapter);
        adapter = NULL;
        adapterIdx++;
    }
    printf("adapters total=%d\n", adapterIdx);

    // ---- Media Foundation: HEVC encoder path ----
    MFT_REGISTER_TYPE_INFO outinfo = { MFMediaType_Video, MFVideoFormat_HEVC };
    IMFActivate **acts = NULL;
    UINT32 n = 0;
    hr = MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER,
                   MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER,
                   NULL, &outinfo, &acts, &n);
    printf("MFTEnumEx hr=%08lX n=%u\n", (unsigned long)hr, n);
    if (n && acts) {
        IMFTransform *xf = NULL;
        hr = IMFActivate_ActivateObject(acts[0], &IID_IMFTransform, (void **)&xf);
        printf("ActivateObject hr=%08lX p=%p\n", (unsigned long)hr, (void *)xf);
        if (xf) {
            printf("== IMFActivate (before release) ==\n");
            // IMFActivate was acts[0]; dump ITS slots first (it's still alive? no - use acts[0] before)
            printf("== IMFTransform ==\n");
            slot_of(xf->lpVtbl, (const void *)xf->lpVtbl->GetAttributes, "Xf.GetAttributes", 40);
            slot_of(xf->lpVtbl, (const void *)xf->lpVtbl->GetOutputStreamInfo, "Xf.GetOutputStreamInfo", 40);
            slot_of(xf->lpVtbl, (const void *)xf->lpVtbl->SetInputType, "Xf.SetInputType", 40);
            slot_of(xf->lpVtbl, (const void *)xf->lpVtbl->SetOutputType, "Xf.SetOutputType", 40);
            slot_of(xf->lpVtbl, (const void *)xf->lpVtbl->ProcessEvent, "Xf.ProcessEvent", 40);
            slot_of(xf->lpVtbl, (const void *)xf->lpVtbl->ProcessMessage, "Xf.ProcessMessage", 40);
            slot_of(xf->lpVtbl, (const void *)xf->lpVtbl->ProcessInput, "Xf.ProcessInput", 40);
            slot_of(xf->lpVtbl, (const void *)xf->lpVtbl->ProcessOutput, "Xf.ProcessOutput", 40);

            IMFAttributes *attrs = NULL;
            if (SUCCEEDED(IMFTransform_GetAttributes(xf, &attrs)) && attrs) {
                printf("== IMFAttributes ==\n");
                slot_of(attrs->lpVtbl, (const void *)attrs->lpVtbl->SetUINT32, "Attr.SetUINT32", 64);
                slot_of(attrs->lpVtbl, (const void *)attrs->lpVtbl->SetUINT64, "Attr.SetUINT64", 64);
                slot_of(attrs->lpVtbl, (const void *)attrs->lpVtbl->SetGUID, "Attr.SetGUID", 64);
                IMFAttributes_Release(attrs);
            }

            IMFMediaType *mt = NULL;
            if (SUCCEEDED(MFCreateMediaType(&mt)) && mt) {
                printf("== IMFMediaType(IMFAttributes) ==\n");
                slot_of(mt->lpVtbl, (const void *)mt->lpVtbl->SetGUID, "Mt.SetGUID", 64);
                slot_of(mt->lpVtbl, (const void *)mt->lpVtbl->SetUINT32, "Mt.SetUINT32", 64);
                slot_of(mt->lpVtbl, (const void *)mt->lpVtbl->SetUINT64, "Mt.SetUINT64", 64);
                IMFMediaType_Release(mt);
            }

            // Sample/buffer/event slots via a fresh sample.
            IMFSample *smp = NULL;
            if (SUCCEEDED(MFCreateSample(&smp)) && smp) {
                printf("== IMFSample ==\n");
                slot_of(smp->lpVtbl, (const void *)smp->lpVtbl->AddBuffer, "Smp.AddBuffer", 64);
                slot_of(smp->lpVtbl, (const void *)smp->lpVtbl->SetSampleTime, "Smp.SetSampleTime", 64);
                slot_of(smp->lpVtbl, (const void *)smp->lpVtbl->SetSampleDuration, "Smp.SetSampleDuration", 64);
                slot_of(smp->lpVtbl, (const void *)smp->lpVtbl->GetSampleTime, "Smp.GetSampleTime", 64);
                slot_of(smp->lpVtbl, (const void *)smp->lpVtbl->ConvertToContiguousBuffer, "Smp.ConvertToContiguousBuffer", 64);
                IMFSample_Release(smp);
            }
            IMFMediaBuffer *buf = NULL;
            if (SUCCEEDED(MFCreateMemoryBuffer(16, &buf)) && buf) {
                printf("== IMFMediaBuffer ==\n");
                slot_of(buf->lpVtbl, (const void *)buf->lpVtbl->Lock, "Buf.Lock", 16);
                slot_of(buf->lpVtbl, (const void *)buf->lpVtbl->Unlock, "Buf.Unlock", 16);
                slot_of(buf->lpVtbl, (const void *)buf->lpVtbl->SetCurrentLength, "Buf.SetCurrentLength", 16);
                IMFMediaBuffer_Release(buf);
            }

            IMFMediaEventGenerator *gen = NULL;
            if (SUCCEEDED(IMFTransform_QueryInterface(xf, &IID_IMFMediaEventGenerator, (void **)&gen)) && gen) {
                printf("== IMFMediaEventGenerator ==\n");
                slot_of(gen->lpVtbl, (const void *)gen->lpVtbl->GetEvent, "Gen.GetEvent", 16);
                IMFMediaEventGenerator_Release(gen);
            }
            IMFTransform_Release(xf);
        }
        // IMFActivate slots (object still alive here? ActivateObject keeps it; dump before releasing)
        printf("== IMFActivate ==\n");
        slot_of(acts[0]->lpVtbl, (const void *)acts[0]->lpVtbl->ActivateObject, "Act.ActivateObject", 64);
        for (UINT32 i = 0; i < n; i++) IMFActivate_Release(acts[i]);
        CoTaskMemFree(acts);
    }

    (void)hr;
    return 0;
}
