// Ground truth for the asm host, Media Foundation half: exact IID bytes for the MF interfaces,
// the media-type/attribute GUIDs, and the enum values the encoder path needs.
// Build with the same vcvars64 environment as host-asm\build.ps1:
//   cl /nologo /EHsc print_mf.cpp mfplat.lib mfuuid.lib ole32.lib
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mftransform.h>
#include <mferror.h>
#include <cstdio>

// Prints MASM-safe hex: a leading 0 whenever the high nibble is A-F (MASM reads C1h as an
// identifier, so it must be written 0C1h).
static void uuid_bytes(const char* name, REFGUID g) {
    const unsigned char* p = (const unsigned char*)&g;
    char buf[80];
    int o = 0;
    for (int i = 0; i < 16; ++i)
        o += sprintf_s(buf + o, sizeof(buf) - o, "%s%s%02Xh", i ? "," : "",
                       p[i] >= 0xA0 ? "0" : "", p[i]);
    printf("%-30s db %s\n", name, buf);
}

int main() {
    printf("=== MF interface IIDs ===\n");
    uuid_bytes("IMFTransform", __uuidof(IMFTransform));
    uuid_bytes("IMFMediaType", __uuidof(IMFMediaType));
    uuid_bytes("IMFAttributes", __uuidof(IMFAttributes));
    uuid_bytes("IMFMediaEventGenerator", __uuidof(IMFMediaEventGenerator));
    uuid_bytes("IMFMediaEvent", __uuidof(IMFMediaEvent));
    uuid_bytes("IMFActivate", __uuidof(IMFActivate));
    uuid_bytes("IMFSample", __uuidof(IMFSample));
    uuid_bytes("IMFMediaBuffer", __uuidof(IMFMediaBuffer));
    uuid_bytes("IMFDXGIDeviceManager", __uuidof(IMFDXGIDeviceManager));
    uuid_bytes("IMF2DBuffer", __uuidof(IMF2DBuffer));

    printf("\n=== GUIDs (attribute keys / formats / categories) ===\n");
    uuid_bytes("MFT_CATEGORY_VIDEO_ENCODER", MFT_CATEGORY_VIDEO_ENCODER);
    uuid_bytes("MFMediaType_Video", MFMediaType_Video);
    uuid_bytes("MFVideoFormat_HEVC", MFVideoFormat_HEVC);
    uuid_bytes("MFVideoFormat_NV12", MFVideoFormat_NV12);
    uuid_bytes("MF_MT_MAJOR_TYPE", MF_MT_MAJOR_TYPE);
    uuid_bytes("MF_MT_SUBTYPE", MF_MT_SUBTYPE);
    uuid_bytes("MF_MT_AVG_BITRATE", MF_MT_AVG_BITRATE);
    uuid_bytes("MF_MT_FRAME_SIZE", MF_MT_FRAME_SIZE);
    uuid_bytes("MF_MT_FRAME_RATE", MF_MT_FRAME_RATE);
    uuid_bytes("MF_MT_PIXEL_ASPECT_RATIO", MF_MT_PIXEL_ASPECT_RATIO);
    uuid_bytes("MF_MT_INTERLACE_MODE", MF_MT_INTERLACE_MODE);
    uuid_bytes("MF_MT_ALL_SAMPLES_INDEPENDENT", MF_MT_ALL_SAMPLES_INDEPENDENT);
    uuid_bytes("MF_TRANSFORM_ASYNC_UNLOCK", MF_TRANSFORM_ASYNC_UNLOCK);
    uuid_bytes("MF_LOW_LATENCY", MF_LOW_LATENCY);

    printf("\n=== values ===\n");
    printf("  MF_VERSION                       = 0x%08X\n", (unsigned)MF_VERSION);
    printf("  MFT_ENUM_FLAG_HARDWARE           = 0x%X\n", (unsigned)MFT_ENUM_FLAG_HARDWARE);
    printf("  MFT_ENUM_FLAG_SORTANDFILTER      = 0x%X\n", (unsigned)MFT_ENUM_FLAG_SORTANDFILTER);
    printf("  MFT_MESSAGE_SET_D3D_MANAGER      = 0x%X\n", (unsigned)MFT_MESSAGE_SET_D3D_MANAGER);
    printf("  MFT_MESSAGE_NOTIFY_BEGIN_STREAMING = 0x%X\n", (unsigned)MFT_MESSAGE_NOTIFY_BEGIN_STREAMING);
    printf("  MFT_MESSAGE_NOTIFY_START_OF_STREAM = 0x%X\n", (unsigned)MFT_MESSAGE_NOTIFY_START_OF_STREAM);
    printf("  MFT_MESSAGE_COMMAND_DRAIN        = 0x%X\n", (unsigned)MFT_MESSAGE_COMMAND_DRAIN);
    printf("  METransformNeedInput             = %u\n", (unsigned)METransformNeedInput);
    printf("  METransformHaveOutput            = %u\n", (unsigned)METransformHaveOutput);
    printf("  MF_EVENT_FLAG_NO_WAIT            = 0x%X\n", (unsigned)MF_EVENT_FLAG_NO_WAIT);
    printf("  MF_E_NO_EVENTS_AVAILABLE         = 0x%08X\n", (unsigned)MF_E_NO_EVENTS_AVAILABLE);
    printf("  MF_E_TRANSFORM_NEED_MORE_INPUT   = 0x%08X\n", (unsigned)MF_E_TRANSFORM_NEED_MORE_INPUT);
    printf("  MFT_OUTPUT_STREAM_PROVIDES_SAMPLES = 0x%X\n", (unsigned)MFT_OUTPUT_STREAM_PROVIDES_SAMPLES);
    printf("  MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES = 0x%X\n", (unsigned)MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES);
    printf("  MF_MT_INTERLACE_MODE.PROGRESSIVE = 2 (MFVideoInterlace_Progressive)\n");
    printf("  MFT_OUTPUT_DATA_BUFFER size      = %zu\n", sizeof(MFT_OUTPUT_DATA_BUFFER));
    printf("  MFT_OUTPUT_DATA_BUFFER.pSample off = %zu, .dwStatus off = %zu, .pEvents off = %zu\n",
        offsetof(MFT_OUTPUT_DATA_BUFFER, pSample), offsetof(MFT_OUTPUT_DATA_BUFFER, dwStatus),
        offsetof(MFT_OUTPUT_DATA_BUFFER, pEvents));
    return 0;
}
