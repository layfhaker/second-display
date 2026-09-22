// SecondDisplay host, HolyC port - Media Foundation HEVC Hardware/Software Encoder.
//
// Milestone 3: Encodes NV12 frames from GDI capture into HEVC Annex-B access units.

#define PACK_U64(hi, lo) (((U64)(hi) << 32) | (U64)(lo))

IMFTransform *pTransform = NULL;
IMFMediaEventGenerator *pEventGen = NULL;
Bool enc_is_async = FALSE;

extern U0 SendVideo(I64 sock, I64 pts_us, U8 keyframe, U8 *au, U32 au_len);
extern Bool client_alive;

// Detect HEVC keyframes (VPS=32, SPS=33, PPS=34, IDR_W_RADL=19, IDR_N_LP=20)
Bool IsHevcKeyframe(U8 *data, U32 len)
{
    U32 i = 0;
    while (i + 5 < len) {
        U32 sc = 0;
        if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1) {
            sc = 3;
        } else if (i + 3 < len && data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 0 && data[i + 3] == 1) {
            sc = 4;
        }
        if (sc == 0) {
            i++;
            continue;
        }
        U32 nal_header = i + sc;
        if (nal_header >= len) break;
        U8 nal_type = (data[nal_header] >> 1) & 0x3F;
        if (nal_type == 19 || nal_type == 20 || nal_type == 32 || nal_type == 33 || nal_type == 34) {
            return TRUE;
        }
        i = nal_header + 1;
    }
    return FALSE;
}

Bool enc_need_input = TRUE;
I64 frames_encoded = 0;
I64 bytes_encoded = 0;

Bool EncoderInit(U32 width, U32 height, U32 fps, U32 bitrate)
{
    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    MFStartup(MF_VERSION, MFSTARTUP_NOSOCKET);

    frames_encoded = 0;
    bytes_encoded = 0;
    enc_need_input = TRUE;

    MFT_REGISTER_TYPE_INFO outInfo;
    outInfo.guidMajorType = MFMediaType_Video;
    outInfo.guidSubtype = MFVideoFormat_HEVC;

    IMFActivate **ppActivates = NULL;
    UINT32 count = 0;

    // Try hardware MFT first
    HRESULT hr = MFTEnumEx(
        MFT_CATEGORY_VIDEO_ENCODER,
        MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER,
        NULL,
        &outInfo,
        &ppActivates,
        &count
    );

    if (count == 0 || !ppActivates) {
        "Hardware HEVC MFT not found, trying software/all...\n";
        hr = MFTEnumEx(
            MFT_CATEGORY_VIDEO_ENCODER,
            MFT_ENUM_FLAG_ALL,
            NULL,
            &outInfo,
            &ppActivates,
            &count
        );
    }

    if (count == 0 || !ppActivates) {
        "Error: No HEVC encoder MFT found on system\n";
        return FALSE;
    }

    "Found %u HEVC encoder MFT(s)\n", count;

    pTransform = NULL;
    hr = ppActivates[0]->ActivateObject(IID_IMFTransform, (void**)&pTransform);
    for (UINT32 i = 0; i < count; i++) {
        ppActivates[i]->Release();
    }
    CoTaskMemFree(ppActivates);

    if (FAILED(hr) || !pTransform) {
        "Error: Failed to activate IMFTransform (hr=0x%08X)\n", hr;
        return FALSE;
    }

    // Unlock async and configure low-latency
    IMFAttributes *pAttrs = NULL;
    enc_is_async = FALSE;
    if (SUCCEEDED(pTransform->GetAttributes(&pAttrs))) {
        pAttrs->SetUINT32(MF_TRANSFORM_ASYNC_UNLOCK, 1);
        pAttrs->SetUINT32(MF_LOW_LATENCY, 1);
        enc_is_async = TRUE;
        pAttrs->Release();
    }

    // Configure Output (HEVC)
    IMFMediaType *pOutType = NULL;
    MFCreateMediaType(&pOutType);
    pOutType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    pOutType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_HEVC);
    pOutType->SetUINT32(MF_MT_AVG_BITRATE, bitrate);
    pOutType->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    pOutType->SetUINT64(MF_MT_FRAME_SIZE, PACK_U64(width, height));
    pOutType->SetUINT64(MF_MT_FRAME_RATE, PACK_U64(fps, 1));
    pOutType->SetUINT64(MF_MT_PIXEL_ASPECT_RATIO, PACK_U64(1, 1));
    hr = pTransform->SetOutputType(0, pOutType, 0);
    pOutType->Release();

    if (FAILED(hr)) {
        "Error: SetOutputType failed (hr=0x%08X)\n", hr;
        pTransform->Release();
        pTransform = NULL;
        return FALSE;
    }

    // Configure Input (NV12)
    IMFMediaType *pInType = NULL;
    MFCreateMediaType(&pInType);
    pInType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    pInType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
    pInType->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    pInType->SetUINT64(MF_MT_FRAME_SIZE, PACK_U64(width, height));
    pInType->SetUINT64(MF_MT_FRAME_RATE, PACK_U64(fps, 1));
    pInType->SetUINT64(MF_MT_PIXEL_ASPECT_RATIO, PACK_U64(1, 1));
    hr = pTransform->SetInputType(0, pInType, 0);
    pInType->Release();

    if (FAILED(hr)) {
        "Error: SetInputType failed (hr=0x%08X)\n", hr;
        pTransform->Release();
        pTransform = NULL;
        return FALSE;
    }

    pTransform->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
    pTransform->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);

    pEventGen = NULL;
    if (enc_is_async) {
        hr = pTransform->QueryInterface(IID_IMFMediaEventGenerator, (void**)&pEventGen);
        if (FAILED(hr)) {
            enc_is_async = FALSE;
            pEventGen = NULL;
        }
    }

    "Media Foundation HEVC encoder ready: %ux%u @%ufps (%u bps)\n", width, height, fps, bitrate;
    return TRUE;
}

U0 EncoderCleanup()
{
    if (pTransform) {
        pTransform->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
        if (pEventGen) {
            pEventGen->Release();
            pEventGen = NULL;
        }
        pTransform->Release();
        pTransform = NULL;
    }
    MFShutdown();
    CoUninitialize();
}

Bool EncoderFeedNv12(U8 *nv12_data, U32 len, I64 pts_us, I64 duration_hns)
{
    if (!pTransform) return FALSE;

    IMFMediaBuffer *pBuf = NULL;
    HRESULT hr = MFCreateMemoryBuffer((DWORD)len, &pBuf);
    if (FAILED(hr) || !pBuf) {
        "MFCreateMemoryBuffer failed: 0x%08X\n", hr;
        return FALSE;
    }

    BYTE *pData = NULL;
    hr = pBuf->Lock(&pData, NULL, NULL);
    if (FAILED(hr) || !pData) {
        pBuf->Release();
        return FALSE;
    }

    MemCpy(pData, nv12_data, len);
    pBuf->Unlock();
    pBuf->SetCurrentLength((DWORD)len);

    IMFSample *pSample = NULL;
    hr = MFCreateSample(&pSample);
    if (FAILED(hr) || !pSample) {
        pBuf->Release();
        return FALSE;
    }

    pSample->AddBuffer(pBuf);
    pSample->SetSampleTime(pts_us * 10);
    pSample->SetSampleDuration(duration_hns);

    hr = pTransform->ProcessInput(0, pSample, 0);

    pSample->Release();
    pBuf->Release();

    if (SUCCEEDED(hr)) {
        enc_need_input = FALSE;
        return TRUE;
    }
    return FALSE;
}

Bool EncoderDrainOutput(I64 client_sock)
{
    if (!pTransform) return FALSE;

    MFT_OUTPUT_DATA_BUFFER odb;
    MemSet(&odb, 0, sizeof(odb));
    odb.dwStreamID = 0;

    DWORD status = 0;
    HRESULT hr = pTransform->ProcessOutput(0, 1, &odb, &status);
    if (FAILED(hr)) {
        if (odb.pSample) odb.pSample->Release();
        if (odb.pEvents) odb.pEvents->Release();
        return TRUE;
    }

    if (odb.pSample) {
        LONGLONG sampleTimeHns = 0;
        odb.pSample->GetSampleTime(&sampleTimeHns);
        I64 pts_micros = sampleTimeHns / 10;

        IMFMediaBuffer *pContig = NULL;
        hr = odb.pSample->ConvertToContiguousBuffer(&pContig);
        if (SUCCEEDED(hr) && pContig) {
            BYTE *pEnc = NULL;
            DWORD encLen = 0;
            hr = pContig->Lock(&pEnc, NULL, &encLen);
            if (SUCCEEDED(hr) && pEnc && encLen > 0) {
                U8 is_key = IsHevcKeyframe(pEnc, encLen) ? 1 : 0;
                frames_encoded++;
                bytes_encoded += encLen;
                if (frames_encoded <= 5 || frames_encoded % 60 == 0) {
                    "HEVC Frame #%lld: %u bytes, key=%d, pts=%lld us\n", frames_encoded, encLen, is_key, pts_micros;
                }
                SendVideo(client_sock, pts_micros, is_key, pEnc, encLen);
                pContig->Unlock();
            }
            pContig->Release();
        }
        odb.pSample->Release();
    }

    if (odb.pEvents) {
        odb.pEvents->Release();
    }

    return TRUE;
}

// Poll MFT events and drain output if available.
// Returns after one pass: the caller paces the loop, so never busy-spin here.
// The MFT queues at most one pending input; feeding faster than it signals
// METransformNeedInput only piles frames into our own queue (commit blowup).
Bool EncoderPollEvents(I64 client_sock)
{
    if (!pEventGen) {
        enc_need_input = TRUE;
        return TRUE;
    }

    IMFMediaEvent *pEvent = NULL;
    HRESULT hr = pEventGen->GetEvent(MF_EVENT_FLAG_NO_WAIT, &pEvent);
    if (hr == MF_E_NO_EVENTS_AVAILABLE || FAILED(hr)) {
        return TRUE;
    }

    MediaEventType met = MEUnknown;
    pEvent->GetType(&met);
    pEvent->Release();

    if (met == METransformNeedInput) {
        enc_need_input = TRUE;
    } else if (met == METransformHaveOutput) {
        EncoderDrainOutput(client_sock);
    }

    return TRUE;
}
