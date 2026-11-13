// WASAPI render, for the Windows Grabber. See include/NAGWASAPI.h.
//
// Shared mode only. Exclusive mode would take the device from every other app and skip its
// effects, Windows Sonic and Dolby Atmos for Headphones among them.
//
// The stream is opened at the device's own mix rate, as 32-bit float with as many channels as the
// Grabber's bus and the speaker mask that width means. When that is not the device's own mix
// (a stereo bus on a 7.1 device, say), AUTOCONVERTPCM has Windows convert it, which is also what
// lets a spatial-sound endpoint place each labelled channel where it belongs.
//
// The GUIDs are written out here rather than taken from INITGUID, so this file and the capture's
// cannot clash over who defines what.

#define COBJMACROS
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <avrt.h>
#include <functiondiscoverykeys_devpkey.h>
#include <ks.h>
#include <ksmedia.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#include "NAGWASAPI.h"

static const GUID R_IID_IAudioClient =
    {0x1cb9ad4c, 0xdbfa, 0x4c32, {0xb1, 0x78, 0xc2, 0xf5, 0x68, 0xa7, 0x03, 0xb2}};
static const GUID R_IID_IAudioRenderClient =
    {0xf294acfc, 0x3146, 0x4483, {0xa7, 0xbf, 0xad, 0xdc, 0xa7, 0xc2, 0x60, 0xe2}};
static const GUID R_IID_IMMDeviceEnumerator =
    {0xa95664d2, 0x9614, 0x4f35, {0xa7, 0x46, 0xde, 0x8d, 0xb6, 0x36, 0x17, 0xe6}};
static const GUID R_CLSID_MMDeviceEnumerator =
    {0xbcde0395, 0xe52f, 0x467c, {0x8e, 0x3d, 0xc4, 0x57, 0x92, 0x91, 0x69, 0x2e}};
static const GUID R_SUBTYPE_IEEE_FLOAT =
    {0x00000003, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};
static const PROPERTYKEY R_PKEY_Device_FriendlyName =
    {{0xa45c254e, 0xdf1c, 0x4efd, {0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0}}, 14};

// 20 ms of endpoint buffer. Shared mode fires the event once per engine period (10 ms on nearly
// every device), so this is one period being played while the next is written: enough that a
// late wake loses nothing, short enough to add little to the playout delay.
#define NAG_RENDER_BUFFER_HNS 200000

struct NAGWasapiRender {
    IMMDeviceEnumerator *enumerator;
    IMMDevice *device;
    IAudioClient *client;
    IAudioRenderClient *render;
    HANDLE event;
    HANDLE mmcss;
    UINT32 bufferFrames;
    int channels;
    int started;
    int comInitialised;
    WCHAR deviceID[256];
};

static void rsay(char *error, int bytes, const char *what, HRESULT hr) {
    if (!error || bytes <= 0) return;
    _snprintf_s(error, (size_t)bytes, _TRUNCATE, "%s (0x%08lX)", what, (unsigned long)hr);
}

/// The speaker mask for a bus width, in the engine's sense of each width (`Downmix.swift`):
/// stereo, 4.0 as a quad, 5.1 with its surrounds at the back as Windows labels them, and 7.1 with
/// both pairs — the caller reorders the engine's sides and rears to Windows' order. Any other width
/// is direct out: channel n to output n, unlabelled.
static DWORD maskFor(int channels) {
    switch (channels) {
    case 1: return SPEAKER_FRONT_CENTER;
    case 2: return SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT;
    case 4: return SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT | SPEAKER_BACK_LEFT | SPEAKER_BACK_RIGHT;
    case 6: return KSAUDIO_SPEAKER_5POINT1;
    case 8: return KSAUDIO_SPEAKER_7POINT1_SURROUND;
    default: return 0;
    }
}

static int friendlyName(IMMDevice *device, char *name, int nameBytes) {
    if (!name || nameBytes <= 0) return -1;
    name[0] = 0;
    IPropertyStore *store = NULL;
    if (FAILED(IMMDevice_OpenPropertyStore(device, STGM_READ, &store)) || !store) return -1;
    PROPVARIANT value;
    PropVariantInit(&value);
    int result = -1;
    if (SUCCEEDED(IPropertyStore_GetValue(store, &R_PKEY_Device_FriendlyName, &value))
        && value.vt == VT_LPWSTR && value.pwszVal) {
        if (WideCharToMultiByte(CP_UTF8, 0, value.pwszVal, -1, name, nameBytes, NULL, NULL) > 0) result = 0;
        name[nameBytes - 1] = 0;
    }
    PropVariantClear(&value);
    IPropertyStore_Release(store);
    return result;
}

static void releaseRender(NAGWasapiRender *r) {
    if (!r) return;
    if (r->render) { IAudioRenderClient_Release(r->render); r->render = NULL; }
    if (r->client) { IAudioClient_Release(r->client); r->client = NULL; }
    if (r->device) { IMMDevice_Release(r->device); r->device = NULL; }
    if (r->enumerator) { IMMDeviceEnumerator_Release(r->enumerator); r->enumerator = NULL; }
    if (r->event) { CloseHandle(r->event); r->event = NULL; }
    if (r->mmcss) { AvRevertMmThreadCharacteristics(r->mmcss); r->mmcss = NULL; }
}

/// One attempt at opening the client at `channels`. The client is made afresh each time: an
/// IAudioClient that failed Initialize cannot be initialised again.
static HRESULT initialise(NAGWasapiRender *r, int channels, int rate) {
    if (r->client) { IAudioClient_Release(r->client); r->client = NULL; }
    HRESULT hr = IMMDevice_Activate(r->device, &R_IID_IAudioClient, CLSCTX_ALL, NULL, (void **)&r->client);
    if (FAILED(hr)) return hr;

    WAVEFORMATEXTENSIBLE format;
    memset(&format, 0, sizeof format);
    format.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
    format.Format.nChannels = (WORD)channels;
    format.Format.nSamplesPerSec = (DWORD)rate;
    format.Format.wBitsPerSample = 32;
    format.Format.nBlockAlign = (WORD)(channels * 4);
    format.Format.nAvgBytesPerSec = (DWORD)rate * format.Format.nBlockAlign;
    format.Format.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
    format.Samples.wValidBitsPerSample = 32;
    format.dwChannelMask = maskFor(channels);
    format.SubFormat = R_SUBTYPE_IEEE_FLOAT;

    DWORD flags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK
                | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
    return IAudioClient_Initialize(r->client, AUDCLNT_SHAREMODE_SHARED, flags,
                                   NAG_RENDER_BUFFER_HNS, 0, (WAVEFORMATEX *)&format, NULL);
}

NAGWasapiRender *nag_render_open(int busChannels, int *sampleRate, int *deviceChannels,
                                 int *openedChannels, int *bufferFrames,
                                 char *name, int nameBytes, char *deviceID, int idBytes,
                                 char *error, int errorBytes) {
    return nag_render_open_device(NULL, NULL, busChannels, sampleRate, deviceChannels, openedChannels, bufferFrames,
                                  name, nameBytes, deviceID, idBytes, error, errorBytes);
}

/// An active playback endpoint by its ID (UTF-8), or NULL. The caller releases it.
static IMMDevice *activeDevice(IMMDeviceEnumerator *enumerator, const char *idUtf8) {
    if (!enumerator || !idUtf8 || !idUtf8[0]) return NULL;
    WCHAR wide[256];
    if (MultiByteToWideChar(CP_UTF8, 0, idUtf8, -1, wide, 256) <= 0) return NULL;
    IMMDevice *device = NULL;
    if (FAILED(IMMDeviceEnumerator_GetDevice(enumerator, wide, &device)) || !device) return NULL;
    DWORD state = 0;
    if (FAILED(IMMDevice_GetState(device, &state)) || state != DEVICE_STATE_ACTIVE) {
        IMMDevice_Release(device);
        return NULL;
    }
    return device;
}

NAGWasapiRender *nag_render_open_device(const char *wantedID, int *usedFallback,
                                        int busChannels, int *sampleRate, int *deviceChannels,
                                        int *openedChannels, int *bufferFrames,
                                        char *name, int nameBytes, char *deviceID, int idBytes,
                                        char *error, int errorBytes) {
    HRESULT hr;
    if (usedFallback) *usedFallback = 0;
    NAGWasapiRender *r = (NAGWasapiRender *)calloc(1, sizeof(NAGWasapiRender));
    if (!r) { rsay(error, errorBytes, "out of memory", 0); return NULL; }

    hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (hr == S_OK || hr == S_FALSE) r->comInitialised = 1;
    else if (hr != RPC_E_CHANGED_MODE) { rsay(error, errorBytes, "CoInitializeEx failed", hr); free(r); return NULL; }

    // This thread is the audio thread from here on: MMCSS schedules it ahead of ordinary work.
    // Not fatal if refused; the audio still plays, with less protection from a busy machine.
    DWORD task = 0;
    r->mmcss = AvSetMmThreadCharacteristicsW(L"Pro Audio", &task);

    hr = CoCreateInstance(&R_CLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL,
                          &R_IID_IMMDeviceEnumerator, (void **)&r->enumerator);
    if (FAILED(hr)) { rsay(error, errorBytes, "no audio device enumerator", hr); goto failed; }

    // The chosen device if it is there; otherwise the default, and the caller is told.
    r->device = activeDevice(r->enumerator, wantedID);
    if (!r->device) {
        if (wantedID && wantedID[0] && usedFallback) *usedFallback = 1;
        hr = IMMDeviceEnumerator_GetDefaultAudioEndpoint(r->enumerator, eRender, eConsole, &r->device);
        if (FAILED(hr)) { rsay(error, errorBytes, "there is no default playback device", hr); goto failed; }
    }

    {
        LPWSTR id = NULL;
        if (SUCCEEDED(IMMDevice_GetId(r->device, &id)) && id) {
            wcsncpy_s(r->deviceID, 256, id, _TRUNCATE);
            CoTaskMemFree(id);
        }
        if (deviceID && idBytes > 0) {
            deviceID[0] = 0;
            WideCharToMultiByte(CP_UTF8, 0, r->deviceID, -1, deviceID, idBytes, NULL, NULL);
            deviceID[idBytes - 1] = 0;
        }
    }
    friendlyName(r->device, name, nameBytes);

    // The mix format, for the rate to open at and the width the device offers.
    hr = IMMDevice_Activate(r->device, &R_IID_IAudioClient, CLSCTX_ALL, NULL, (void **)&r->client);
    if (FAILED(hr)) { rsay(error, errorBytes, "the playback device would not open", hr); goto failed; }
    WAVEFORMATEX *mix = NULL;
    hr = IAudioClient_GetMixFormat(r->client, &mix);
    if (FAILED(hr) || !mix) { rsay(error, errorBytes, "the device has no mix format", hr); goto failed; }
    int rate = (int)mix->nSamplesPerSec;
    int mixChannels = (int)mix->nChannels;
    CoTaskMemFree(mix);

    int channels = busChannels < 1 ? 2 : busChannels;
    hr = initialise(r, channels, rate);
    if (FAILED(hr) && channels != 2) {
        // A width the device will not take even converted: stereo, which every device takes.
        channels = 2;
        hr = initialise(r, channels, rate);
    }
    if (FAILED(hr)) { rsay(error, errorBytes, "the playback device refused the stream", hr); goto failed; }
    r->channels = channels;

    r->event = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (!r->event) { rsay(error, errorBytes, "could not make the render event", (HRESULT)GetLastError()); goto failed; }
    hr = IAudioClient_SetEventHandle(r->client, r->event);
    if (FAILED(hr)) { rsay(error, errorBytes, "the device would not take the render event", hr); goto failed; }

    hr = IAudioClient_GetBufferSize(r->client, &r->bufferFrames);
    if (FAILED(hr)) { rsay(error, errorBytes, "the device has no buffer size", hr); goto failed; }

    hr = IAudioClient_GetService(r->client, &R_IID_IAudioRenderClient, (void **)&r->render);
    if (FAILED(hr)) { rsay(error, errorBytes, "the render service would not open", hr); goto failed; }

    if (sampleRate) *sampleRate = rate;
    if (deviceChannels) *deviceChannels = mixChannels;
    if (openedChannels) *openedChannels = channels;
    if (bufferFrames) *bufferFrames = (int)r->bufferFrames;
    if (error && errorBytes > 0) error[0] = 0;
    return r;

failed:
    releaseRender(r);
    if (r->comInitialised) CoUninitialize();
    free(r);
    return NULL;
}

int nag_render_start(NAGWasapiRender *r) {
    if (!r || !r->client || !r->render) return -1;
    if (r->started) return 0;
    // The buffer starts full of silence, so the first period the device plays is not garbage and
    // the first event arrives a period from now rather than at once.
    BYTE *data = NULL;
    if (SUCCEEDED(IAudioRenderClient_GetBuffer(r->render, r->bufferFrames, &data))) {
        IAudioRenderClient_ReleaseBuffer(r->render, r->bufferFrames, AUDCLNT_BUFFERFLAGS_SILENT);
    }
    if (FAILED(IAudioClient_Start(r->client))) return -1;
    r->started = 1;
    return 0;
}

int nag_render_wait(NAGWasapiRender *r, int timeoutMs) {
    if (!r || !r->client || !r->started) return -1;
    DWORD waited = WaitForSingleObject(r->event, (DWORD)(timeoutMs < 0 ? 0 : timeoutMs));
    if (waited == WAIT_FAILED) return -1;
    UINT32 padding = 0;
    if (FAILED(IAudioClient_GetCurrentPadding(r->client, &padding))) return -1;
    if (padding >= r->bufferFrames) return 0;
    return (int)(r->bufferFrames - padding);
}

float *nag_render_buffer(NAGWasapiRender *r, int frames) {
    if (!r || !r->render || frames <= 0) return NULL;
    BYTE *data = NULL;
    if (FAILED(IAudioRenderClient_GetBuffer(r->render, (UINT32)frames, &data)) || !data) return NULL;
    return (float *)data;
}

int nag_render_release(NAGWasapiRender *r, int frames) {
    if (!r || !r->render) return -1;
    return FAILED(IAudioRenderClient_ReleaseBuffer(r->render, (UINT32)frames, 0)) ? -1 : 0;
}

void nag_render_close(NAGWasapiRender *r) {
    if (!r) return;
    if (r->started && r->client) IAudioClient_Stop(r->client);
    r->started = 0;
    releaseRender(r);
    if (r->comInitialised) CoUninitialize();
    free(r);
}

int nag_render_default_changed(NAGWasapiRender *r) {
    if (!r || !r->enumerator || r->deviceID[0] == 0) return 0;
    IMMDevice *now = NULL;
    if (FAILED(IMMDeviceEnumerator_GetDefaultAudioEndpoint(r->enumerator, eRender, eConsole, &now)) || !now) {
        return 0;
    }
    int changed = 0;
    LPWSTR id = NULL;
    if (SUCCEEDED(IMMDevice_GetId(now, &id)) && id) {
        changed = (wcscmp(id, r->deviceID) != 0);
        CoTaskMemFree(id);
    }
    IMMDevice_Release(now);
    return changed;
}

int nag_render_devices(char *ids, char *names, int *channels, int recordBytes, int max) {
    int count = 0;
    int initialised = 0;
    HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (hr == S_OK || hr == S_FALSE) initialised = 1;
    IMMDeviceEnumerator *enumerator = NULL;
    IMMDeviceCollection *collection = NULL;
    if (FAILED(CoCreateInstance(&R_CLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL, &R_IID_IMMDeviceEnumerator,
                                (void **)&enumerator)) || !enumerator) goto done;
    if (FAILED(IMMDeviceEnumerator_EnumAudioEndpoints(enumerator, eRender, DEVICE_STATE_ACTIVE, &collection)) || !collection) goto done;
    UINT n = 0;
    IMMDeviceCollection_GetCount(collection, &n);
    for (UINT i = 0; i < n && count < max; i++) {
        IMMDevice *device = NULL;
        if (FAILED(IMMDeviceCollection_Item(collection, i, &device)) || !device) continue;
        char *id = ids + count * recordBytes;
        char *name = names + count * recordBytes;
        id[0] = 0; name[0] = 0;
        LPWSTR wide = NULL;
        if (SUCCEEDED(IMMDevice_GetId(device, &wide)) && wide) {
            WideCharToMultiByte(CP_UTF8, 0, wide, -1, id, recordBytes, NULL, NULL);
            id[recordBytes - 1] = 0;
            CoTaskMemFree(wide);
        }
        friendlyName(device, name, recordBytes);
        channels[count] = 2;
        IAudioClient *client = NULL;
        if (SUCCEEDED(IMMDevice_Activate(device, &R_IID_IAudioClient, CLSCTX_ALL, NULL, (void **)&client)) && client) {
            WAVEFORMATEX *mix = NULL;
            if (SUCCEEDED(IAudioClient_GetMixFormat(client, &mix)) && mix) {
                channels[count] = (int)mix->nChannels;
                CoTaskMemFree(mix);
            }
            IAudioClient_Release(client);
        }
        IMMDevice_Release(device);
        if (id[0]) count++;
    }
done:
    if (collection) IMMDeviceCollection_Release(collection);
    if (enumerator) IMMDeviceEnumerator_Release(enumerator);
    if (initialised) CoUninitialize();
    return count;
}

int nag_render_device_active(NAGWasapiRender *r, const char *idUtf8) {
    if (!r || !r->enumerator) return 0;
    IMMDevice *device = activeDevice(r->enumerator, idUtf8);
    if (!device) return 0;
    IMMDevice_Release(device);
    return 1;
}
