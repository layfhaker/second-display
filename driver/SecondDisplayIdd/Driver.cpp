// SecondDisplay Indirect Display Driver (IddCx, UMDF)
// Stage 3a: creates one virtual monitor at the tablet's aspect ratio.
// Frames from the OS swap-chain are acquired and discarded; the host captures
// this virtual monitor externally for now. Stage 3b will ship frames from here.
//
// Adapted from the Microsoft IndirectDisplay sample (MIT).

#include "Driver.h"

#ifndef D3DKMDT_VSS_OTHER
#define D3DKMDT_VSS_OTHER 255
#endif

using namespace Microsoft::WRL;
using namespace SecondDisplay;

extern "C" DRIVER_INITIALIZE DriverEntry;

EVT_WDF_DRIVER_DEVICE_ADD IddDeviceAdd;
EVT_WDF_DEVICE_D0_ENTRY IddDeviceD0Entry;

EVT_IDD_CX_ADAPTER_INIT_FINISHED IddAdapterInitFinished;
EVT_IDD_CX_ADAPTER_COMMIT_MODES IddAdapterCommitModes;
EVT_IDD_CX_PARSE_MONITOR_DESCRIPTION IddParseMonitorDescription;
EVT_IDD_CX_MONITOR_GET_DEFAULT_DESCRIPTION_MODES IddMonitorGetDefaultModes;
EVT_IDD_CX_MONITOR_QUERY_TARGET_MODES IddMonitorQueryModes;
EVT_IDD_CX_MONITOR_ASSIGN_SWAPCHAIN IddMonitorAssignSwapChain;
EVT_IDD_CX_MONITOR_UNASSIGN_SWAPCHAIN IddMonitorUnassignSwapChain;

// ---------------------------------------------------------------------------
// Mode table — preferred is a tablet-aspect (~1.415:1) mode for fullscreen.
// ---------------------------------------------------------------------------
struct ModeEntry { DWORD Width; DWORD Height; DWORD VSync; };
static const ModeEntry s_Modes[] =
{
    { 2000, 1414, 60 },  // tablet aspect (preferred)
    { 1920, 1080, 60 },
    { 2560, 1440, 60 },
};

// A minimal EDID. The monitor description is otherwise driven by the mode list;
// IddCx requires a valid-ish 128-byte block.
static const BYTE s_Edid[128] =
{
    0x00,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0x00,0x36,0x8E,0x00,0x01,0x00,0x00,0x00,0x00,
    0x00,0x21,0x01,0x04,0xA5,0x2B,0x1E,0x78,0x06,0xEE,0x91,0xA3,0x54,0x4C,0x99,0x26,
    0x0F,0x50,0x54,0x00,0x00,0x00,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,
    0x01,0x01,0x01,0x01,0x01,0x01,0x9E,0x1A,0x00,0xA0,0x50,0x00,0x16,0x30,0x30,0x20,
    0x36,0x00,0x25,0xA4,0x10,0x00,0x00,0x18,0x00,0x00,0x00,0xFC,0x00,0x53,0x65,0x63,
    0x6F,0x6E,0x64,0x44,0x69,0x73,0x70,0x0A,0x20,0x20,0x00,0x00,0x00,0x10,0x00,0x00,
    0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x10,0x00,0x00,
    0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xB6,
};

// ===========================================================================
// Direct3DDevice
// ===========================================================================
Direct3DDevice::Direct3DDevice(LUID adapterLuid) : AdapterLuid(adapterLuid) {}
Direct3DDevice::Direct3DDevice() : AdapterLuid{} {}

HRESULT Direct3DDevice::Init()
{
    HRESULT hr = CreateDXGIFactory2(0, IID_PPV_ARGS(&DxgiFactory));
    if (FAILED(hr)) return hr;

    hr = DxgiFactory->EnumAdapterByLuid(AdapterLuid, IID_PPV_ARGS(&Adapter));
    if (FAILED(hr)) return hr;

    hr = D3D11CreateDevice(Adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, 0,
                           nullptr, 0, D3D11_SDK_VERSION, &Device, nullptr, &DeviceContext);
    if (FAILED(hr)) return hr;

    return S_OK;
}

// ===========================================================================
// SwapChainProcessor
// ===========================================================================
SwapChainProcessor::SwapChainProcessor(IDDCX_SWAPCHAIN hSwapChain, std::shared_ptr<Direct3DDevice> device, HANDLE newFrameEvent)
    : m_hSwapChain(hSwapChain), m_Device(device), m_hAvailableBufferEvent(newFrameEvent)
{
    m_hTerminateEvent.Attach(CreateEvent(nullptr, FALSE, FALSE, nullptr));
    m_hThread.Attach(CreateThread(nullptr, 0, RunThread, this, 0, nullptr));
}

SwapChainProcessor::~SwapChainProcessor()
{
    SetEvent(m_hTerminateEvent.Get());
    if (m_hThread.Get())
        WaitForSingleObject(m_hThread.Get(), INFINITE);
}

DWORD CALLBACK SwapChainProcessor::RunThread(LPVOID Argument)
{
    reinterpret_cast<SwapChainProcessor*>(Argument)->Run();
    return 0;
}

void SwapChainProcessor::Run()
{
    DWORD taskIndex = 0;
    HANDLE avTask = AvSetMmThreadCharacteristicsW(L"Distribution", &taskIndex);
    RunCore();
    WdfObjectDelete((WDFOBJECT)m_hSwapChain);
    m_hSwapChain = nullptr;
    if (avTask) AvRevertMmThreadCharacteristics(avTask);
}

void SwapChainProcessor::RunCore()
{
    ComPtr<IDXGIDevice> dxgiDevice;
    if (FAILED(m_Device->Device.As(&dxgiDevice))) return;

    IDARG_IN_SWAPCHAINSETDEVICE setDevice = {};
    setDevice.pDevice = dxgiDevice.Get();
    if (FAILED(IddCxSwapChainSetDevice(m_hSwapChain, &setDevice))) return;

    for (;;)
    {
        ComPtr<IDXGIResource> acquiredBuffer;
        IDARG_OUT_RELEASEANDACQUIREBUFFER buffer = {};
        HRESULT hr = IddCxSwapChainReleaseAndAcquireBuffer(m_hSwapChain, &buffer);

        if (hr == E_PENDING)
        {
            HANDLE waitHandles[] = { m_hAvailableBufferEvent, m_hTerminateEvent.Get() };
            DWORD waitResult = WaitForMultipleObjects(2, waitHandles, FALSE, 16);
            if (waitResult == WAIT_OBJECT_0 || waitResult == WAIT_TIMEOUT)
                continue;                 // new buffer, or periodic tick
            else
                break;                    // terminate
        }
        else if (SUCCEEDED(hr))
        {
            // Stage 3a: we don't process the frame; just release it back.
            acquiredBuffer.Attach(buffer.MetaData.pSurface);
            acquiredBuffer.Reset();
            IddCxSwapChainFinishedProcessingFrame(m_hSwapChain);
        }
        else
        {
            break; // device lost or other error
        }
    }
}

// ===========================================================================
// IndirectDeviceContext
// ===========================================================================
IndirectDeviceContext::IndirectDeviceContext(WDFDEVICE wdfDevice) : m_WdfDevice(wdfDevice) {}
IndirectDeviceContext::~IndirectDeviceContext() {}

void IndirectDeviceContext::InitAdapter()
{
    IDDCX_ADAPTER_CAPS caps = {};
    caps.Size = sizeof(caps);
    caps.MaxMonitorsSupported = 1;
    caps.EndPointDiagnostics.Size = sizeof(caps.EndPointDiagnostics);
    caps.EndPointDiagnostics.GammaSupport = IDDCX_FEATURE_IMPLEMENTATION_NONE;
    caps.EndPointDiagnostics.TransmissionType = IDDCX_TRANSMISSION_TYPE_OTHER;
    caps.EndPointDiagnostics.pEndPointFriendlyName = L"SecondDisplay Virtual Monitor";
    caps.EndPointDiagnostics.pEndPointManufacturerName = L"SecondDisplay";
    caps.EndPointDiagnostics.pEndPointModelName = L"SD-VDISP";

    IDDCX_ENDPOINT_VERSION ver = {};
    ver.Size = sizeof(ver);
    ver.MajorVer = 1;
    caps.EndPointDiagnostics.pFirmwareVersion = &ver;
    caps.EndPointDiagnostics.pHardwareVersion = &ver;

    WDF_OBJECT_ATTRIBUTES attr;
    WDF_OBJECT_ATTRIBUTES_INIT(&attr);

    IDARG_IN_ADAPTER_INIT init = {};
    init.WdfDevice = m_WdfDevice;
    init.pCaps = &caps;
    init.ObjectAttributes = &attr;

    IDARG_OUT_ADAPTER_INIT initOut = {};
    NTSTATUS status = IddCxAdapterInitAsync(&init, &initOut);
    if (NT_SUCCESS(status))
        m_Adapter = initOut.AdapterObject;
}

void IndirectDeviceContext::FinishInit(UINT /*connectorIndex*/)
{
    IDDCX_MONITOR_INFO monitorInfo = {};
    monitorInfo.Size = sizeof(monitorInfo);
    monitorInfo.MonitorType = DISPLAYCONFIG_OUTPUT_TECHNOLOGY_HDMI;
    monitorInfo.ConnectorIndex = 0;
    monitorInfo.MonitorDescription.Size = sizeof(monitorInfo.MonitorDescription);
    monitorInfo.MonitorDescription.Type = IDDCX_MONITOR_DESCRIPTION_TYPE_EDID;
    monitorInfo.MonitorDescription.DataSize = sizeof(s_Edid);
    monitorInfo.MonitorDescription.pData = const_cast<BYTE*>(s_Edid);
    CoCreateGuid(&monitorInfo.MonitorContainerId);

    WDF_OBJECT_ATTRIBUTES monAttr;
    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&monAttr, MonitorContextWrapper);
    monAttr.EvtCleanupCallback = [](WDFOBJECT obj)
    {
        auto* w = WdfObjectGet_MonitorContextWrapper(obj);
        if (w) w->Cleanup();
    };

    IDARG_IN_MONITORCREATE create = {};
    create.ObjectAttributes = &monAttr;
    create.pMonitorInfo = &monitorInfo;

    IDARG_OUT_MONITORCREATE createOut = {};
    NTSTATUS status = IddCxMonitorCreate(m_Adapter, &create, &createOut);
    if (!NT_SUCCESS(status)) return;
    m_Monitor = createOut.MonitorObject;

    IDARG_OUT_MONITORARRIVAL arrivalOut = {};
    IddCxMonitorArrival(m_Monitor, &arrivalOut);
}

// ===========================================================================
// Mode helpers
// ===========================================================================
static IDDCX_MONITOR_MODE MakeMonitorMode(DWORD w, DWORD h, DWORD vsync, IDDCX_MONITOR_MODE_ORIGIN origin)
{
    IDDCX_MONITOR_MODE mode = {};
    mode.Size = sizeof(mode);
    mode.Origin = origin;
    mode.MonitorVideoSignalInfo.totalSize = { w + 80, h + 40 };
    mode.MonitorVideoSignalInfo.activeSize = { w, h };
    mode.MonitorVideoSignalInfo.vSyncFreq = { vsync, 1 };
    mode.MonitorVideoSignalInfo.hSyncFreq = { vsync * (h + 40), 1 };
    mode.MonitorVideoSignalInfo.pixelRate = (UINT64)(w + 80) * (h + 40) * vsync;
    mode.MonitorVideoSignalInfo.scanLineOrdering = DISPLAYCONFIG_SCANLINE_ORDERING_PROGRESSIVE;
    mode.MonitorVideoSignalInfo.AdditionalSignalInfo.videoStandard = D3DKMDT_VSS_OTHER;
    mode.MonitorVideoSignalInfo.AdditionalSignalInfo.vSyncFreqDivider = 0;
    return mode;
}

static IDDCX_TARGET_MODE MakeTargetMode(DWORD w, DWORD h, DWORD vsync)
{
    IDDCX_TARGET_MODE mode = {};
    mode.Size = sizeof(mode);
    auto& sig = mode.TargetVideoSignalInfo.targetVideoSignalInfo;
    sig.totalSize = { w + 80, h + 40 };
    sig.activeSize = { w, h };
    sig.vSyncFreq = { vsync, 1 };
    sig.hSyncFreq = { vsync * (h + 40), 1 };
    sig.pixelRate = (UINT64)(w + 80) * (h + 40) * vsync;
    sig.scanLineOrdering = DISPLAYCONFIG_SCANLINE_ORDERING_PROGRESSIVE;
    sig.AdditionalSignalInfo.videoStandard = D3DKMDT_VSS_OTHER;
    sig.AdditionalSignalInfo.vSyncFreqDivider = 1;
    return mode;
}

// ===========================================================================
// IddCx callbacks
// ===========================================================================
NTSTATUS IddAdapterInitFinished(IDDCX_ADAPTER adapter, const IDARG_IN_ADAPTER_INIT_FINISHED* args)
{
    auto* wrapper = WdfObjectGet_IndirectDeviceContextWrapper(adapter);
    if (NT_SUCCESS(args->AdapterInitStatus) && wrapper && wrapper->pContext)
        wrapper->pContext->FinishInit(0);
    return STATUS_SUCCESS;
}

NTSTATUS IddAdapterCommitModes(IDDCX_ADAPTER, const IDARG_IN_COMMITMODES*)
{
    return STATUS_SUCCESS; // accept whatever the OS commits
}

NTSTATUS IddParseMonitorDescription(const IDARG_IN_PARSEMONITORDESCRIPTION* inArgs, IDARG_OUT_PARSEMONITORDESCRIPTION* outArgs)
{
    outArgs->MonitorModeBufferOutputCount = ARRAYSIZE(s_Modes);
    if (inArgs->MonitorModeBufferInputCount < ARRAYSIZE(s_Modes))
        return (inArgs->MonitorModeBufferInputCount > 0) ? STATUS_BUFFER_TOO_SMALL : STATUS_SUCCESS;

    for (DWORD i = 0; i < ARRAYSIZE(s_Modes); i++)
    {
        inArgs->pMonitorModes[i] = MakeMonitorMode(s_Modes[i].Width, s_Modes[i].Height, s_Modes[i].VSync,
            i == 0 ? IDDCX_MONITOR_MODE_ORIGIN_MONITORDESCRIPTOR : IDDCX_MONITOR_MODE_ORIGIN_DRIVER);
    }
    outArgs->PreferredMonitorModeIdx = 0;
    return STATUS_SUCCESS;
}

NTSTATUS IddMonitorGetDefaultModes(IDDCX_MONITOR, const IDARG_IN_GETDEFAULTDESCRIPTIONMODES*, IDARG_OUT_GETDEFAULTDESCRIPTIONMODES* outArgs)
{
    outArgs->DefaultMonitorModeBufferOutputCount = 0;
    return STATUS_SUCCESS;
}

NTSTATUS IddMonitorQueryModes(IDDCX_MONITOR, const IDARG_IN_QUERYTARGETMODES* inArgs, IDARG_OUT_QUERYTARGETMODES* outArgs)
{
    outArgs->TargetModeBufferOutputCount = ARRAYSIZE(s_Modes);
    if (inArgs->TargetModeBufferInputCount < ARRAYSIZE(s_Modes))
        return (inArgs->TargetModeBufferInputCount > 0) ? STATUS_BUFFER_TOO_SMALL : STATUS_SUCCESS;

    for (DWORD i = 0; i < ARRAYSIZE(s_Modes); i++)
        inArgs->pTargetModes[i] = MakeTargetMode(s_Modes[i].Width, s_Modes[i].Height, s_Modes[i].VSync);
    return STATUS_SUCCESS;
}

NTSTATUS IddMonitorAssignSwapChain(IDDCX_MONITOR monitor, const IDARG_IN_SETSWAPCHAIN* inArgs)
{
    auto* monCtx = WdfObjectGet_MonitorContextWrapper(monitor);
    auto device = std::make_shared<Direct3DDevice>(inArgs->RenderAdapterLuid);
    if (FAILED(device->Init()))
    {
        WdfObjectDelete((WDFOBJECT)inArgs->hSwapChain);
        return STATUS_SUCCESS;
    }
    auto* proc = new SwapChainProcessor(inArgs->hSwapChain, device, inArgs->hNextSurfaceAvailable);
    if (monCtx) monCtx->pSwapChain = proc;
    return STATUS_SUCCESS;
}

NTSTATUS IddMonitorUnassignSwapChain(IDDCX_MONITOR monitor)
{
    auto* monCtx = WdfObjectGet_MonitorContextWrapper(monitor);
    if (monCtx && monCtx->pSwapChain)
    {
        delete monCtx->pSwapChain;
        monCtx->pSwapChain = nullptr;
    }
    return STATUS_SUCCESS;
}

// ===========================================================================
// WDF plumbing
// ===========================================================================
NTSTATUS IddDeviceD0Entry(WDFDEVICE device, WDF_POWER_DEVICE_STATE)
{
    auto* wrapper = WdfObjectGet_IndirectDeviceContextWrapper(device);
    if (wrapper && wrapper->pContext)
        wrapper->pContext->InitAdapter();
    return STATUS_SUCCESS;
}

NTSTATUS IddDeviceAdd(WDFDRIVER, PWDFDEVICE_INIT deviceInit)
{
    WDF_PNPPOWER_EVENT_CALLBACKS pnpPower;
    WDF_PNPPOWER_EVENT_CALLBACKS_INIT(&pnpPower);
    pnpPower.EvtDeviceD0Entry = IddDeviceD0Entry;
    WdfDeviceInitSetPnpPowerEventCallbacks(deviceInit, &pnpPower);

    IDD_CX_CLIENT_CONFIG config;
    IDD_CX_CLIENT_CONFIG_INIT(&config);
    config.EvtIddCxAdapterInitFinished = IddAdapterInitFinished;
    config.EvtIddCxAdapterCommitModes = IddAdapterCommitModes;
    config.EvtIddCxParseMonitorDescription = IddParseMonitorDescription;
    config.EvtIddCxMonitorGetDefaultDescriptionModes = IddMonitorGetDefaultModes;
    config.EvtIddCxMonitorQueryTargetModes = IddMonitorQueryModes;
    config.EvtIddCxMonitorAssignSwapChain = IddMonitorAssignSwapChain;
    config.EvtIddCxMonitorUnassignSwapChain = IddMonitorUnassignSwapChain;

    NTSTATUS status = IddCxDeviceInitConfig(deviceInit, &config);
    if (!NT_SUCCESS(status)) return status;

    WDF_OBJECT_ATTRIBUTES attr;
    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attr, IndirectDeviceContextWrapper);
    attr.EvtCleanupCallback = [](WDFOBJECT obj)
    {
        auto* w = WdfObjectGet_IndirectDeviceContextWrapper(obj);
        if (w) w->Cleanup();
    };

    WDFDEVICE device;
    status = WdfDeviceCreate(&deviceInit, &attr, &device);
    if (!NT_SUCCESS(status)) return status;

    status = IddCxDeviceInitialize(device);
    if (!NT_SUCCESS(status)) return status;

    auto* wrapper = WdfObjectGet_IndirectDeviceContextWrapper(device);
    wrapper->pContext = new IndirectDeviceContext(device);
    return status;
}

extern "C" NTSTATUS DriverEntry(PDRIVER_OBJECT driverObject, PUNICODE_STRING registryPath)
{
    WDF_DRIVER_CONFIG config;
    WDF_DRIVER_CONFIG_INIT(&config, IddDeviceAdd);

    NTSTATUS status = WdfDriverCreate(driverObject, registryPath, WDF_NO_OBJECT_ATTRIBUTES, &config, WDF_NO_HANDLE);
    return status;
}
