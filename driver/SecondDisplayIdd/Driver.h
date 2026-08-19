#pragma once

#include <windows.h>
#include <bugcodes.h>
#include <wudfwdm.h>
#include <wdf.h>

#include <iddcx.h>

#include <dxgi1_5.h>
#include <d3d11_2.h>
#include <avrt.h>
#include <wrl.h>

#include <memory>
#include <vector>

namespace Microsoft::WRL::Wrappers
{
    // (using WRL ComPtr etc.)
}

namespace SecondDisplay
{
    // Manages a D3D device/context bound to a given LUID, used to consume the swap-chain.
    struct Direct3DDevice
    {
        Direct3DDevice(LUID AdapterLuid);
        Direct3DDevice();
        HRESULT Init();

        LUID AdapterLuid;
        Microsoft::WRL::ComPtr<IDXGIFactory5> DxgiFactory;
        Microsoft::WRL::ComPtr<IDXGIAdapter1> Adapter;
        Microsoft::WRL::ComPtr<ID3D11Device> Device;
        Microsoft::WRL::ComPtr<ID3D11DeviceContext> DeviceContext;
    };

    // Pulls frames from the IddCx swap-chain on a dedicated thread.
    // Stage 3a: acquires and immediately releases each buffer (discard) so the
    // OS keeps compositing. Stage 3b will ship frames to the host here.
    class SwapChainProcessor
    {
    public:
        SwapChainProcessor(IDDCX_SWAPCHAIN hSwapChain, std::shared_ptr<Direct3DDevice> Device, HANDLE NewFrameEvent);
        ~SwapChainProcessor();

    private:
        static DWORD CALLBACK RunThread(LPVOID Argument);
        void Run();
        void RunCore();

        IDDCX_SWAPCHAIN m_hSwapChain;
        std::shared_ptr<Direct3DDevice> m_Device;
        HANDLE m_hAvailableBufferEvent;
        Microsoft::WRL::Wrappers::HandleT<Microsoft::WRL::Wrappers::HandleTraits::HANDLENullTraits> m_hThread;
        Microsoft::WRL::Wrappers::Event m_hTerminateEvent;
    };

    class IndirectDeviceContext
    {
    public:
        IndirectDeviceContext(WDFDEVICE WdfDevice);
        virtual ~IndirectDeviceContext();

        void InitAdapter();
        void FinishInit(UINT ConnectorIndex);

    protected:
        WDFDEVICE m_WdfDevice;
        IDDCX_ADAPTER m_Adapter{};
        IDDCX_MONITOR m_Monitor{};
    };
}

struct IndirectDeviceContextWrapper
{
    SecondDisplay::IndirectDeviceContext* pContext;
    void Cleanup() { delete pContext; pContext = nullptr; }
};

WDF_DECLARE_CONTEXT_TYPE(IndirectDeviceContextWrapper);

struct MonitorContextWrapper
{
    SecondDisplay::SwapChainProcessor* pSwapChain;
    void Cleanup() { delete pSwapChain; pSwapChain = nullptr; }
};

WDF_DECLARE_CONTEXT_TYPE(MonitorContextWrapper);
