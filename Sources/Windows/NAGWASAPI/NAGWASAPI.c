// WASAPI loopback capture. See include/NAGWASAPI.h.
//
// Shared mode, so this takes a copy of whatever the playback device is already mixing and
// changes nothing about it: no other app is interrupted and nothing is muted. The format is the
// device's own mix format, which on Windows is all but always 32-bit float; the other PCM widths
// are converted here anyway, so an unusual device cannot stop the Sender.

#define COBJMACROS
#define INITGUID
#include <initguid.h>
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <functiondiscoverykeys_devpkey.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>
#include <string.h>

#include "NAGWASAPICapture.h"

// The IIDs the Windows SDK leaves to uuid.lib. Defined here so nothing extra has to be linked.
DEFINE_GUID(NAG_IID_IAudioClient,
            0x1cb9ad4c, 0xdbfa, 0x4c32, 0xb1, 0x78, 0xc2, 0xf5, 0x68, 0xa7, 0x03, 0xb2);
DEFINE_GUID(NAG_IID_IAudioCaptureClient,
            0xc8adbd64, 0xe71e, 0x48a0, 0xa4, 0xde, 0x18, 0x5c, 0x39, 0x5c, 0xd3, 0x17);
DEFINE_GUID(NAG_IID_IMMDeviceEnumerator,
            0xa95664d2, 0x9614, 0x4f35, 0xa7, 0x46, 0xde, 0x8d, 0xb6, 0x36, 0x17, 0xe6);
// The float sub-format, which the SDK leaves to ksuser.lib.
DEFINE_GUID(NAG_KSDATAFORMAT_SUBTYPE_IEEE_FLOAT,
            0x00000003, 0x0000, 0x0010, 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71);
DEFINE_GUID(NAG_CLSID_MMDeviceEnumerator,
            0xbcde0395, 0xe52f, 0x467c, 0x8e, 0x3d, 0xc4, 0x57, 0x92, 0x91, 0x69, 0x2e);

// 200 ms of slack in the endpoint buffer: enough that a late read loses nothing, short enough
// that a restart is not heard as a long gap.
#define NAG_BUFFER_HNS 2000000

// The struct itself is in NAGWASAPICapture.h, shared with NAGWASAPISources.c.

void nag_capture_say(char *error, int bytes, const char *what, HRESULT hr) {
    if (!error || bytes <= 0) return;
    _snprintf_s(error, (size_t)bytes, _TRUNCATE, "%s (0x%08lX)", what, (unsigned long)hr);
}

void nag_capture_release_all(NAGWasapiCapture *c) {
    if (!c) return;
    if (c->capture) { IAudioCaptureClient_Release(c->capture); c->capture = NULL; }
    if (c->client) { IAudioClient_Release(c->client); c->client = NULL; }
    if (c->device) { IMMDevice_Release(c->device); c->device = NULL; }
    if (c->enumerator) { IMMDeviceEnumerator_Release(c->enumerator); c->enumerator = NULL; }
    if (c->mix) { CoTaskMemFree(c->mix); c->mix = NULL; }
    if (c->event) { CloseHandle(c->event); c->event = NULL; }
    if (c->target) { CloseHandle(c->target); c->target = NULL; }
}

/// Reads `c->mix` into the fields `nag_wasapi_read` converts by. 0 if it is a format this reads.
int nag_capture_take_format(NAGWasapiCapture *c, char *error, int errorBytes) {
    c->rate = (int)c->mix->nSamplesPerSec;
    c->channels = (int)c->mix->nChannels;
    c->bytesPerSample = c->mix->wBitsPerSample / 8;
    c->isFloat = 0;
    if (c->mix->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
        c->isFloat = 1;
    } else if (c->mix->wFormatTag == WAVE_FORMAT_EXTENSIBLE
               && c->mix->cbSize >= sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)) {
        WAVEFORMATEXTENSIBLE *ext = (WAVEFORMATEXTENSIBLE *)c->mix;
        if (IsEqualGUID(&ext->SubFormat, &NAG_KSDATAFORMAT_SUBTYPE_IEEE_FLOAT)) c->isFloat = 1;
    }
    if (!c->isFloat && c->bytesPerSample != 2 && c->bytesPerSample != 3 && c->bytesPerSample != 4) {
        nag_capture_say(error, errorBytes, "the device's format is one this does not read", 0);
        return -1;
    }
    return 0;
}

NAGWasapiCapture *nag_wasapi_open(int *sampleRate, int *channels, char *error, int errorBytes) {
    HRESULT hr;
    NAGWasapiCapture *c = (NAGWasapiCapture *)calloc(1, sizeof(NAGWasapiCapture));
    if (!c) { nag_capture_say(error, errorBytes, "out of memory", 0); return NULL; }

    // The multithreaded apartment: the capture thread owns this object and nothing marshals.
    hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (hr == S_OK || hr == S_FALSE) c->comInitialised = 1;
    else if (hr != RPC_E_CHANGED_MODE) { nag_capture_say(error, errorBytes, "CoInitializeEx failed", hr); free(c); return NULL; }

    hr = CoCreateInstance(&NAG_CLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL,
                          &NAG_IID_IMMDeviceEnumerator, (void **)&c->enumerator);
    if (FAILED(hr)) { nag_capture_say(error, errorBytes, "no audio device enumerator", hr); goto failed; }

    hr = IMMDeviceEnumerator_GetDefaultAudioEndpoint(c->enumerator, eRender, eConsole, &c->device);
    if (FAILED(hr)) { nag_capture_say(error, errorBytes, "there is no default playback device", hr); goto failed; }

    {
        LPWSTR id = NULL;
        if (SUCCEEDED(IMMDevice_GetId(c->device, &id)) && id) {
            wcsncpy_s(c->deviceID, 256, id, _TRUNCATE);
            CoTaskMemFree(id);
        }
    }

    hr = IMMDevice_Activate(c->device, &NAG_IID_IAudioClient, CLSCTX_ALL, NULL, (void **)&c->client);
    if (FAILED(hr)) { nag_capture_say(error, errorBytes, "the playback device would not open", hr); goto failed; }

    hr = IAudioClient_GetMixFormat(c->client, &c->mix);
    if (FAILED(hr) || !c->mix) { nag_capture_say(error, errorBytes, "the device has no mix format", hr); goto failed; }

    if (nag_capture_take_format(c, error, errorBytes) != 0) goto failed;

    hr = IAudioClient_Initialize(c->client, AUDCLNT_SHAREMODE_SHARED,
                                 AUDCLNT_STREAMFLAGS_LOOPBACK, NAG_BUFFER_HNS, 0, c->mix, NULL);
    if (FAILED(hr)) { nag_capture_say(error, errorBytes, "loopback capture was refused", hr); goto failed; }

    hr = IAudioClient_GetService(c->client, &NAG_IID_IAudioCaptureClient, (void **)&c->capture);
    if (FAILED(hr)) { nag_capture_say(error, errorBytes, "the capture service would not open", hr); goto failed; }

    if (sampleRate) *sampleRate = c->rate;
    if (channels) *channels = c->channels;
    if (error && errorBytes > 0) error[0] = 0;
    return c;

failed:
    nag_capture_release_all(c);
    if (c->comInitialised) CoUninitialize();
    free(c);
    return NULL;
}

int nag_wasapi_start(NAGWasapiCapture *c) {
    if (!c || !c->client) return -1;
    if (c->started) return 0;
    if (FAILED(IAudioClient_Start(c->client))) return -1;
    c->started = 1;
    return 0;
}

void nag_wasapi_stop(NAGWasapiCapture *c) {
    if (!c || !c->client || !c->started) return;
    IAudioClient_Stop(c->client);
    c->started = 0;
}

void nag_wasapi_close(NAGWasapiCapture *c) {
    if (!c) return;
    nag_wasapi_stop(c);
    nag_capture_release_all(c);
    if (c->comInitialised) CoUninitialize();
    free(c);
}

int nag_wasapi_read(NAGWasapiCapture *c, float *dest, int maxFrames) {
    if (!c || !c->capture || !c->started || !dest || maxFrames <= 0) return -1;
    int written = 0;
    for (;;) {
        UINT32 packet = 0;
        HRESULT hr = IAudioCaptureClient_GetNextPacketSize(c->capture, &packet);
        if (FAILED(hr)) return -1;
        if (packet == 0) break;

        BYTE *data = NULL;
        UINT32 frames = 0;
        DWORD flags = 0;
        hr = IAudioCaptureClient_GetBuffer(c->capture, &data, &frames, &flags, NULL, NULL);
        if (hr == AUDCLNT_S_BUFFER_EMPTY) break;
        if (FAILED(hr)) return -1;

        // More than the caller asked for: leave the packet where it is and come back for it.
        if (written + (int)frames > maxFrames) {
            IAudioCaptureClient_ReleaseBuffer(c->capture, 0);
            break;
        }

        float *out = dest + (size_t)written * (size_t)c->channels;
        size_t samples = (size_t)frames * (size_t)c->channels;
        if ((flags & AUDCLNT_BUFFERFLAGS_SILENT) || !data) {
            memset(out, 0, samples * sizeof(float));
        } else if (c->isFloat && c->bytesPerSample == 4) {
            memcpy(out, data, samples * sizeof(float));
        } else if (c->bytesPerSample == 2) {
            const short *in = (const short *)data;
            for (size_t i = 0; i < samples; i++) out[i] = (float)in[i] * (1.0f / 32768.0f);
        } else if (c->bytesPerSample == 3) {
            const unsigned char *in = (const unsigned char *)data;
            for (size_t i = 0; i < samples; i++) {
                int v = (int)((unsigned)in[i * 3] | ((unsigned)in[i * 3 + 1] << 8)
                              | ((unsigned)in[i * 3 + 2] << 16));
                if (v & 0x800000) v -= 0x1000000;            // sign-extend 24-bit
                out[i] = (float)v * (1.0f / 8388608.0f);
            }
        } else {
            const int *in = (const int *)data;
            for (size_t i = 0; i < samples; i++) out[i] = (float)in[i] * (1.0f / 2147483648.0f);
        }

        IAudioCaptureClient_ReleaseBuffer(c->capture, frames);
        written += (int)frames;
        if (written >= maxFrames) break;
    }
    return written;
}

int nag_wasapi_device_name(NAGWasapiCapture *c, char *buffer, int bytes) {
    if (!c || !c->device || !buffer || bytes <= 0) return -1;
    buffer[0] = 0;
    IPropertyStore *store = NULL;
    if (FAILED(IMMDevice_OpenPropertyStore(c->device, STGM_READ, &store)) || !store) return -1;
    PROPVARIANT name;
    PropVariantInit(&name);
    int result = -1;
    if (SUCCEEDED(IPropertyStore_GetValue(store, &PKEY_Device_FriendlyName, &name))
        && name.vt == VT_LPWSTR && name.pwszVal) {
        if (WideCharToMultiByte(CP_UTF8, 0, name.pwszVal, -1, buffer, bytes, NULL, NULL) > 0) result = 0;
        buffer[bytes - 1] = 0;
    }
    PropVariantClear(&name);
    IPropertyStore_Release(store);
    return result;
}

int nag_wasapi_default_changed(NAGWasapiCapture *c) {
    if (!c || !c->enumerator || c->deviceID[0] == 0) return 0;
    // Only the whole-system capture follows the default device; an input device or one app is
    // the same source whichever device is the default.
    if (c->kind != NAG_SOURCE_DEFAULT_LOOPBACK && c->kind != NAG_SOURCE_PROCESS_EXCLUDE) return 0;
    IMMDevice *now = NULL;
    if (FAILED(IMMDeviceEnumerator_GetDefaultAudioEndpoint(c->enumerator, eRender, eConsole, &now)) || !now) {
        return 0;
    }
    int changed = 0;
    LPWSTR id = NULL;
    if (SUCCEEDED(IMMDevice_GetId(now, &id)) && id) {
        changed = (wcscmp(id, c->deviceID) != 0);
        CoTaskMemFree(id);
    }
    IMMDevice_Release(now);
    return changed;
}

int nag_capture_friendly_name(IMMDevice *device, char *name, int nameBytes) {
    if (!name || nameBytes <= 0) return -1;
    name[0] = 0;
    IPropertyStore *store = NULL;
    if (FAILED(IMMDevice_OpenPropertyStore(device, STGM_READ, &store)) || !store) return -1;
    PROPVARIANT value;
    PropVariantInit(&value);
    int result = -1;
    if (SUCCEEDED(IPropertyStore_GetValue(store, &PKEY_Device_FriendlyName, &value))
        && value.vt == VT_LPWSTR && value.pwszVal) {
        if (WideCharToMultiByte(CP_UTF8, 0, value.pwszVal, -1, name, nameBytes, NULL, NULL) > 0) result = 0;
        name[nameBytes - 1] = 0;
    }
    PropVariantClear(&value);
    IPropertyStore_Release(store);
    return result;
}

int nag_wasapi_default_device(char *name, int nameBytes, int *sampleRate, int *channels) {
    HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    int owned = (hr == S_OK || hr == S_FALSE);
    if (!owned && hr != RPC_E_CHANGED_MODE) return -1;

    IMMDeviceEnumerator *enumerator = NULL;
    IMMDevice *device = NULL;
    IAudioClient *client = NULL;
    WAVEFORMATEX *mix = NULL;
    int result = -1;

    if (FAILED(CoCreateInstance(&NAG_CLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL,
                                &NAG_IID_IMMDeviceEnumerator, (void **)&enumerator))) goto done;
    if (FAILED(IMMDeviceEnumerator_GetDefaultAudioEndpoint(enumerator, eRender, eConsole, &device))) goto done;
    if (nag_capture_friendly_name(device, name, nameBytes) != 0) goto done;
    result = 0;
    // The rate is a bonus: a device that will not say is still worth naming.
    if (SUCCEEDED(IMMDevice_Activate(device, &NAG_IID_IAudioClient, CLSCTX_ALL, NULL, (void **)&client))
        && SUCCEEDED(IAudioClient_GetMixFormat(client, &mix)) && mix) {
        if (sampleRate) *sampleRate = (int)mix->nSamplesPerSec;
        if (channels) *channels = (int)mix->nChannels;
    }

done:
    if (mix) CoTaskMemFree(mix);
    if (client) IAudioClient_Release(client);
    if (device) IMMDevice_Release(device);
    if (enumerator) IMMDeviceEnumerator_Release(enumerator);
    if (owned) CoUninitialize();
    return result;
}
