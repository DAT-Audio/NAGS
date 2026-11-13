// What the Sender copies: process loopback, input devices, and the lists a Source
// menu needs. See include/NAGWASAPI.h.
//
// **Process loopback** (Windows 10 2004 and later) is the Windows equivalent of the Mac's process
// tap: a loopback of one process tree's audio, or of everything but one process tree, on its way
// to whatever device it plays on. It is asked for through `ActivateAudioInterfaceAsync`, which
// answers on a worker thread through a completion handler; the handler is written out here as a C
// vtable and the opening thread waits on an event for it.
//
// The GUIDs are written out here, as in the render file, so no file clashes over who defines what.

#define COBJMACROS
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <audiopolicy.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#include "NAGWASAPICapture.h"

static const GUID S_IID_IUnknown =
    {0x00000000, 0x0000, 0x0000, {0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}};
static const GUID S_IID_IAgileObject =
    {0x94ea2b94, 0xe9cc, 0x49e0, {0xc0, 0xff, 0xee, 0x64, 0xca, 0x8f, 0x5b, 0x90}};
static const GUID S_IID_IActivateAudioInterfaceCompletionHandler =
    {0x41d949ab, 0x9862, 0x444a, {0x80, 0xf6, 0xc2, 0x61, 0x33, 0x4d, 0xa5, 0xeb}};
static const GUID S_IID_IAudioClient =
    {0x1cb9ad4c, 0xdbfa, 0x4c32, {0xb1, 0x78, 0xc2, 0xf5, 0x68, 0xa7, 0x03, 0xb2}};
static const GUID S_IID_IAudioCaptureClient =
    {0xc8adbd64, 0xe71e, 0x48a0, {0xa4, 0xde, 0x18, 0x5c, 0x39, 0x5c, 0xd3, 0x17}};
static const GUID S_IID_IMMDeviceEnumerator =
    {0xa95664d2, 0x9614, 0x4f35, {0xa7, 0x46, 0xde, 0x8d, 0xb6, 0x36, 0x17, 0xe6}};
static const GUID S_CLSID_MMDeviceEnumerator =
    {0xbcde0395, 0xe52f, 0x467c, {0x8e, 0x3d, 0xc4, 0x57, 0x92, 0x91, 0x69, 0x2e}};
static const GUID S_IID_IAudioSessionManager2 =
    {0x77aa99a0, 0x1bd6, 0x484f, {0x8b, 0xc7, 0x2c, 0x65, 0x4c, 0x9a, 0x9b, 0x6f}};
static const GUID S_IID_IAudioSessionControl2 =
    {0xbfb7ff88, 0x7239, 0x4fc9, {0x8f, 0xa2, 0x07, 0xc9, 0x50, 0xbe, 0x9c, 0x6d}};
static const GUID S_SUBTYPE_IEEE_FLOAT =
    {0x00000003, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};

/// `AUDIOCLIENT_ACTIVATION_PARAMS`, written out: the SDK only declares it when the build targets
/// Windows 10 2004 or later, and this is compiled for older targets too. Same layout.
typedef struct {
    int activationType;                  // 1: AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK
    DWORD targetProcessId;
    int processLoopbackMode;             // 0: include the target's tree, 1: exclude it
} NagActivationParams;

static const WCHAR *const processLoopbackDevice = L"VAD\\Process_Loopback";

// 200 ms of slack in the endpoint buffer, as the device loopback has.
#define S_BUFFER_HNS 2000000

static int beginCOM(void) {
    HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (hr == S_OK || hr == S_FALSE) return 1;
    return hr == RPC_E_CHANGED_MODE ? 0 : -1;
}

static void toUtf8(const WCHAR *text, char *out, int bytes) {
    if (!out || bytes <= 0) return;
    out[0] = 0;
    if (text && WideCharToMultiByte(CP_UTF8, 0, text, -1, out, bytes, NULL, NULL) <= 0) out[0] = 0;
    out[bytes - 1] = 0;
}

unsigned nag_wasapi_own_pid(void) { return (unsigned)GetCurrentProcessId(); }

// MARK: - The completion handler

/// `IActivateAudioInterfaceCompletionHandler` in C. It must also answer `IAgileObject`: the
/// activation calls it on a worker thread and refuses a handler that would need marshalling.
/// Reference-counted, because the pending operation holds it too and may outlive a timed-out wait.
typedef struct {
    IActivateAudioInterfaceCompletionHandler iface;   // first, so the object is its interface
    volatile LONG refs;
    HANDLE done;
    HRESULT result;
    IUnknown *activated;
} Completion;

static HRESULT STDMETHODCALLTYPE completionQueryInterface(IActivateAudioInterfaceCompletionHandler *self,
                                                         REFIID riid, void **out) {
    if (!out) return E_POINTER;
    if (IsEqualIID(riid, &S_IID_IUnknown) || IsEqualIID(riid, &S_IID_IAgileObject)
        || IsEqualIID(riid, &S_IID_IActivateAudioInterfaceCompletionHandler)) {
        InterlockedIncrement(&((Completion *)self)->refs);
        *out = self;
        return S_OK;
    }
    *out = NULL;
    return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE completionAddRef(IActivateAudioInterfaceCompletionHandler *self) {
    return (ULONG)InterlockedIncrement(&((Completion *)self)->refs);
}

static ULONG STDMETHODCALLTYPE completionRelease(IActivateAudioInterfaceCompletionHandler *self) {
    Completion *c = (Completion *)self;
    LONG left = InterlockedDecrement(&c->refs);
    if (left == 0) {
        if (c->activated) IUnknown_Release(c->activated);
        if (c->done) CloseHandle(c->done);
        free(c);
    }
    return (ULONG)left;
}

/// Takes the result here, inside the callback, where the documentation says to.
static HRESULT STDMETHODCALLTYPE completionActivateCompleted(IActivateAudioInterfaceCompletionHandler *self,
                                                            IActivateAudioInterfaceAsyncOperation *operation) {
    Completion *c = (Completion *)self;
    HRESULT result = E_FAIL;
    IUnknown *activated = NULL;
    HRESULT hr = IActivateAudioInterfaceAsyncOperation_GetActivateResult(operation, &result, &activated);
    if (FAILED(hr)) result = hr;
    if (FAILED(result) && activated) { IUnknown_Release(activated); activated = NULL; }
    c->result = result;
    c->activated = activated;
    SetEvent(c->done);
    return S_OK;
}

static IActivateAudioInterfaceCompletionHandlerVtbl completionVtbl = {
    completionQueryInterface, completionAddRef, completionRelease, completionActivateCompleted
};

/// Activates a process loopback audio client for `pid`, include or exclude. Waits up to five
/// seconds; activation is quick when it works at all.
static HRESULT activateProcessLoopback(DWORD pid, int exclude, IAudioClient **client) {
    *client = NULL;
    Completion *c = (Completion *)calloc(1, sizeof(Completion));
    if (!c) return E_OUTOFMEMORY;
    c->iface.lpVtbl = &completionVtbl;
    c->refs = 1;
    c->result = E_FAIL;
    c->done = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!c->done) { free(c); return E_FAIL; }

    NagActivationParams params;
    params.activationType = 1;
    params.targetProcessId = pid;
    params.processLoopbackMode = exclude ? 1 : 0;
    PROPVARIANT activation;
    PropVariantInit(&activation);
    activation.vt = VT_BLOB;
    activation.blob.cbSize = sizeof(params);
    activation.blob.pBlobData = (BYTE *)&params;

    IActivateAudioInterfaceAsyncOperation *operation = NULL;
    HRESULT hr = ActivateAudioInterfaceAsync(processLoopbackDevice, &S_IID_IAudioClient, &activation,
                                             &c->iface, &operation);
    if (SUCCEEDED(hr)) {
        if (WaitForSingleObject(c->done, 5000) != WAIT_OBJECT_0) {
            hr = HRESULT_FROM_WIN32(ERROR_TIMEOUT);
        } else if (FAILED(c->result) || !c->activated) {
            hr = FAILED(c->result) ? c->result : E_NOINTERFACE;
        } else {
            hr = IUnknown_QueryInterface(c->activated, &S_IID_IAudioClient, (void **)client);
        }
    }
    if (operation) IActivateAudioInterfaceAsyncOperation_Release(operation);
    completionRelease(&c->iface);
    return hr;
}

// MARK: - Opening

static DWORD maskFor(int channels) {
    switch (channels) {
    case 1: return 0x4;                  // centre
    case 2: return 0x3;                  // front left, right
    case 4: return 0x33;                 // fronts and backs
    case 6: return 0x3F;                 // 5.1
    case 8: return 0x63F;                // 7.1 surround
    default: return 0;
    }
}

/// Activates and initialises a process loopback at `channels` × `rate`, float. The client is
/// activated afresh for each try: one whose Initialize failed is not asked again.
static HRESULT openProcessClient(NAGWasapiCapture *c, DWORD pid, int exclude, int channels, int rate) {
    if (c->client) { IAudioClient_Release(c->client); c->client = NULL; }
    HRESULT hr = activateProcessLoopback(pid, exclude, &c->client);
    if (FAILED(hr)) return hr;

    WAVEFORMATEXTENSIBLE format;
    memset(&format, 0, sizeof(format));
    format.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
    format.Format.nChannels = (WORD)channels;
    format.Format.nSamplesPerSec = (DWORD)rate;
    format.Format.wBitsPerSample = 32;
    format.Format.nBlockAlign = (WORD)(channels * 4);
    format.Format.nAvgBytesPerSec = (DWORD)(rate * channels * 4);
    format.Format.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
    format.Samples.wValidBitsPerSample = 32;
    format.dwChannelMask = maskFor(channels);
    format.SubFormat = S_SUBTYPE_IEEE_FLOAT;

    hr = IAudioClient_Initialize(c->client, AUDCLNT_SHAREMODE_SHARED,
                                 AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK
                                 | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM,
                                 S_BUFFER_HNS, 0, (WAVEFORMATEX *)&format, NULL);
    if (FAILED(hr)) { IAudioClient_Release(c->client); c->client = NULL; return hr; }
    c->rate = rate;
    c->channels = channels;
    c->bytesPerSample = 4;
    c->isFloat = 1;
    return S_OK;
}

static void keepDeviceID(NAGWasapiCapture *c) {
    LPWSTR id = NULL;
    if (c->device && SUCCEEDED(IMMDevice_GetId(c->device, &id)) && id) {
        wcsncpy_s(c->deviceID, 256, id, _TRUNCATE);
        CoTaskMemFree(id);
    }
}

NAGWasapiCapture *nag_wasapi_open_source(int kind, const char *deviceID, unsigned pid,
                                         int wantChannels, int *sampleRate, int *channels,
                                         char *error, int errorBytes) {
    if (kind == NAG_SOURCE_DEFAULT_LOOPBACK) return nag_wasapi_open(sampleRate, channels, error, errorBytes);

    HRESULT hr;
    NAGWasapiCapture *c = (NAGWasapiCapture *)calloc(1, sizeof(NAGWasapiCapture));
    if (!c) { nag_capture_say(error, errorBytes, "out of memory", 0); return NULL; }
    c->kind = kind;

    int com = beginCOM();
    if (com < 0) { nag_capture_say(error, errorBytes, "CoInitializeEx failed", 0); free(c); return NULL; }
    c->comInitialised = com;

    hr = CoCreateInstance(&S_CLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL,
                          &S_IID_IMMDeviceEnumerator, (void **)&c->enumerator);
    if (FAILED(hr)) { nag_capture_say(error, errorBytes, "no audio device enumerator", hr); goto failed; }

    if (kind == NAG_SOURCE_INPUT) {
        if (!deviceID || !deviceID[0]) { nag_capture_say(error, errorBytes, "no input device was named", 0); goto failed; }
        WCHAR wide[256];
        if (MultiByteToWideChar(CP_UTF8, 0, deviceID, -1, wide, 256) <= 0) {
            nag_capture_say(error, errorBytes, "the input device's ID is not readable", 0);
            goto failed;
        }
        hr = IMMDeviceEnumerator_GetDevice(c->enumerator, wide, &c->device);
        DWORD state = 0;
        if (SUCCEEDED(hr)) IMMDevice_GetState(c->device, &state);
        if (FAILED(hr) || state != DEVICE_STATE_ACTIVE) {
            nag_capture_say(error, errorBytes, "the input device is not connected", hr);
            goto failed;
        }
        keepDeviceID(c);
        hr = IMMDevice_Activate(c->device, &S_IID_IAudioClient, CLSCTX_ALL, NULL, (void **)&c->client);
        if (FAILED(hr)) { nag_capture_say(error, errorBytes, "the input device would not open", hr); goto failed; }
        hr = IAudioClient_GetMixFormat(c->client, &c->mix);
        if (FAILED(hr) || !c->mix) { nag_capture_say(error, errorBytes, "the input device has no mix format", hr); goto failed; }
        if (nag_capture_take_format(c, error, errorBytes) != 0) goto failed;
        // Shared, and no loopback flag: a copy of what the device records, at its own format,
        // which takes nothing from any other app recording from it.
        hr = IAudioClient_Initialize(c->client, AUDCLNT_SHAREMODE_SHARED, 0, S_BUFFER_HNS, 0, c->mix, NULL);
        if (FAILED(hr)) { nag_capture_say(error, errorBytes, "the input device refused to record", hr); goto failed; }
    } else if (kind == NAG_SOURCE_PROCESS_INCLUDE || kind == NAG_SOURCE_PROCESS_EXCLUDE) {
        if (!nag_wasapi_process_loopback_available()) {
            nag_capture_say(error, errorBytes, "process loopback needs Windows 10 2004 or later", 0);
            goto failed;
        }
        if (pid == 0) { nag_capture_say(error, errorBytes, "no process was named", 0); goto failed; }
        // The default playback device: its rate and width to open at, and its name and ID for
        // the status line and for following a change of default.
        int rate = 48000, deviceChannels = 2;
        if (SUCCEEDED(IMMDeviceEnumerator_GetDefaultAudioEndpoint(c->enumerator, eRender, eConsole, &c->device))) {
            keepDeviceID(c);
            IAudioClient *probe = NULL;
            WAVEFORMATEX *mix = NULL;
            if (SUCCEEDED(IMMDevice_Activate(c->device, &S_IID_IAudioClient, CLSCTX_ALL, NULL, (void **)&probe))
                && SUCCEEDED(IAudioClient_GetMixFormat(probe, &mix)) && mix) {
                rate = (int)mix->nSamplesPerSec;
                deviceChannels = (int)mix->nChannels;
            }
            if (mix) CoTaskMemFree(mix);
            if (probe) IAudioClient_Release(probe);
        }
        int want = wantChannels > 0 ? wantChannels : deviceChannels;
        if (want < 1 || want > 8) want = 2;
        int exclude = (kind == NAG_SOURCE_PROCESS_EXCLUDE);
        hr = openProcessClient(c, (DWORD)pid, exclude, want, rate);
        // A width the process loopback will not take falls back to stereo, which it always has.
        if (FAILED(hr) && want != 2) hr = openProcessClient(c, (DWORD)pid, exclude, 2, rate);
        if (FAILED(hr)) { nag_capture_say(error, errorBytes, "process loopback was refused", hr); goto failed; }

        // Event mode is what process loopback supports; the event is set but never waited on,
        // since reading polls on the Sender's own clock as the device loopback does.
        c->event = CreateEventW(NULL, FALSE, FALSE, NULL);
        if (!c->event) { nag_capture_say(error, errorBytes, "could not make an event", HRESULT_FROM_WIN32(GetLastError())); goto failed; }
        hr = IAudioClient_SetEventHandle(c->client, c->event);
        if (FAILED(hr)) { nag_capture_say(error, errorBytes, "process loopback took no event", hr); goto failed; }

        c->target = OpenProcess(SYNCHRONIZE, FALSE, (DWORD)pid);
    } else {
        nag_capture_say(error, errorBytes, "unknown source kind", 0);
        goto failed;
    }

    hr = IAudioClient_GetService(c->client, &S_IID_IAudioCaptureClient, (void **)&c->capture);
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

int nag_wasapi_process_loopback_available(void) {
    typedef LONG (WINAPI *RtlGetVersionFn)(RTL_OSVERSIONINFOW *);
    // `GetVersionEx` lies to an app without a manifest; `RtlGetVersion` does not.
    HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
    RtlGetVersionFn get = ntdll ? (RtlGetVersionFn)(void *)GetProcAddress(ntdll, "RtlGetVersion") : NULL;
    if (!get) return 0;
    RTL_OSVERSIONINFOW info;
    memset(&info, 0, sizeof(info));
    info.dwOSVersionInfoSize = sizeof(info);
    if (get(&info) != 0) return 0;
    if (info.dwMajorVersion > 10) return 1;
    return info.dwMajorVersion == 10 && info.dwBuildNumber >= 19041;
}

int nag_wasapi_target_exited(NAGWasapiCapture *c) {
    if (!c || !c->target) return 0;
    return WaitForSingleObject(c->target, 0) == WAIT_OBJECT_0;
}

// MARK: - Input devices

int nag_wasapi_input_devices(char *ids, char *names, int *channels, int recordBytes, int max) {
    if (!ids || !names || !channels || recordBytes <= 0 || max <= 0) return 0;
    int com = beginCOM();
    if (com < 0) return 0;
    IMMDeviceEnumerator *enumerator = NULL;
    IMMDeviceCollection *collection = NULL;
    int count = 0;
    if (FAILED(CoCreateInstance(&S_CLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL,
                                &S_IID_IMMDeviceEnumerator, (void **)&enumerator))) goto done;
    if (FAILED(IMMDeviceEnumerator_EnumAudioEndpoints(enumerator, eCapture, DEVICE_STATE_ACTIVE, &collection))) goto done;
    UINT total = 0;
    IMMDeviceCollection_GetCount(collection, &total);
    for (UINT i = 0; i < total && count < max; i++) {
        IMMDevice *device = NULL;
        if (FAILED(IMMDeviceCollection_Item(collection, i, &device)) || !device) continue;
        char *id = ids + (size_t)count * recordBytes;
        char *name = names + (size_t)count * recordBytes;
        LPWSTR wide = NULL;
        id[0] = 0;
        if (SUCCEEDED(IMMDevice_GetId(device, &wide)) && wide) { toUtf8(wide, id, recordBytes); CoTaskMemFree(wide); }
        nag_capture_friendly_name(device, name, recordBytes);
        channels[count] = 0;
        IAudioClient *client = NULL;
        WAVEFORMATEX *mix = NULL;
        if (SUCCEEDED(IMMDevice_Activate(device, &S_IID_IAudioClient, CLSCTX_ALL, NULL, (void **)&client))
            && SUCCEEDED(IAudioClient_GetMixFormat(client, &mix)) && mix) {
            channels[count] = (int)mix->nChannels;
        }
        if (mix) CoTaskMemFree(mix);
        if (client) IAudioClient_Release(client);
        IMMDevice_Release(device);
        if (id[0]) count++;
    }
done:
    if (collection) IMMDeviceCollection_Release(collection);
    if (enumerator) IMMDeviceEnumerator_Release(enumerator);
    if (com == 1) CoUninitialize();
    return count;
}

// MARK: - Audio apps

/// The exe's path, by PID. 0 on success.
static int imagePath(DWORD pid, WCHAR *path, DWORD chars) {
    path[0] = 0;
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!process) return -1;
    DWORD size = chars;
    BOOL ok = QueryFullProcessImageNameW(process, 0, path, &size);
    CloseHandle(process);
    return ok ? 0 : -1;
}

static const WCHAR *fileNameOf(const WCHAR *path) {
    const WCHAR *slash = wcsrchr(path, L'\\');
    return slash ? slash + 1 : path;
}

/// What the exe calls itself: its version resource's FileDescription ("Media Player"), else its
/// ProductName. version.dll is loaded when first needed, as nothing links version.lib.
static int describeExe(const WCHAR *path, WCHAR *out, int chars) {
    typedef DWORD (WINAPI *SizeFn)(LPCWSTR, LPDWORD);
    typedef BOOL (WINAPI *InfoFn)(LPCWSTR, DWORD, DWORD, LPVOID);
    typedef BOOL (WINAPI *QueryFn)(LPCVOID, LPCWSTR, LPVOID *, PUINT);
    static HMODULE version = NULL;
    if (!version) version = LoadLibraryW(L"version.dll");
    if (!version) return -1;
    SizeFn size = (SizeFn)(void *)GetProcAddress(version, "GetFileVersionInfoSizeW");
    InfoFn info = (InfoFn)(void *)GetProcAddress(version, "GetFileVersionInfoW");
    QueryFn query = (QueryFn)(void *)GetProcAddress(version, "VerQueryValueW");
    if (!size || !info || !query) return -1;

    DWORD ignored = 0;
    DWORD bytes = size(path, &ignored);
    if (bytes == 0) return -1;
    void *block = malloc(bytes);
    if (!block) return -1;
    int result = -1;
    if (info(path, 0, bytes, block)) {
        WORD *translation = NULL;
        UINT length = 0;
        WORD language = 0x0409, codePage = 0x04B0;
        if (query(block, L"\\VarFileInfo\\Translation", (void **)&translation, &length)
            && translation && length >= 4) {
            language = translation[0];
            codePage = translation[1];
        }
        static const WCHAR *const fields[] = { L"FileDescription", L"ProductName" };
        for (int f = 0; f < 2 && result != 0; f++) {
            WCHAR key[96];
            _snwprintf_s(key, 96, _TRUNCATE, L"\\StringFileInfo\\%04x%04x\\%s", language, codePage, fields[f]);
            WCHAR *value = NULL;
            UINT valueChars = 0;
            if (query(block, key, (void **)&value, &valueChars) && value && valueChars > 1 && value[0]) {
                wcsncpy_s(out, (size_t)chars, value, _TRUNCATE);
                result = 0;
            }
        }
    }
    free(block);
    return result;
}

typedef struct {
    DWORD pid;
    int active;
    WCHAR display[128];
} SessionEntry;

/// The processes with a session on the default playback device, one entry each, less system
/// sounds, expired sessions and this process. Returns how many. COM must be up on this thread.
static int listSessions(SessionEntry *out, int max) {
    IMMDeviceEnumerator *enumerator = NULL;
    IMMDevice *device = NULL;
    IAudioSessionManager2 *manager = NULL;
    IAudioSessionEnumerator *sessions = NULL;
    int count = 0;
    DWORD own = GetCurrentProcessId();
    if (FAILED(CoCreateInstance(&S_CLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL,
                                &S_IID_IMMDeviceEnumerator, (void **)&enumerator))) goto done;
    if (FAILED(IMMDeviceEnumerator_GetDefaultAudioEndpoint(enumerator, eRender, eConsole, &device))) goto done;
    if (FAILED(IMMDevice_Activate(device, &S_IID_IAudioSessionManager2, CLSCTX_ALL, NULL, (void **)&manager))) goto done;
    if (FAILED(IAudioSessionManager2_GetSessionEnumerator(manager, &sessions))) goto done;
    int total = 0;
    IAudioSessionEnumerator_GetCount(sessions, &total);
    for (int i = 0; i < total && count < max; i++) {
        IAudioSessionControl *control = NULL;
        IAudioSessionControl2 *control2 = NULL;
        if (FAILED(IAudioSessionEnumerator_GetSession(sessions, i, &control)) || !control) continue;
        if (SUCCEEDED(IAudioSessionControl_QueryInterface(control, &S_IID_IAudioSessionControl2, (void **)&control2))) {
            DWORD pid = 0;
            AudioSessionState state = AudioSessionStateInactive;
            IAudioSessionControl2_GetState(control2, &state);
            // GetProcessId answers AUDCLNT_S_NO_SINGLE_PROCESS for a session shared by several
            // processes; the PID it gives is still one of them.
            if (IAudioSessionControl2_IsSystemSoundsSession(control2) != S_OK
                && SUCCEEDED(IAudioSessionControl2_GetProcessId(control2, &pid))
                && pid != 0 && pid != own && state != AudioSessionStateExpired) {
                int found = -1;
                for (int j = 0; j < count; j++) if (out[j].pid == pid) { found = j; break; }
                if (found < 0) {
                    found = count++;
                    out[found].pid = pid;
                    out[found].active = 0;
                    out[found].display[0] = 0;
                }
                if (state == AudioSessionStateActive) out[found].active = 1;
                LPWSTR display = NULL;
                // A display name that starts with "@" is a resource reference, not a name.
                if (!out[found].display[0] && SUCCEEDED(IAudioSessionControl2_GetDisplayName(control2, &display))
                    && display && display[0] && display[0] != L'@') {
                    wcsncpy_s(out[found].display, 128, display, _TRUNCATE);
                }
                if (display) CoTaskMemFree(display);
            }
            IAudioSessionControl2_Release(control2);
        }
        IAudioSessionControl_Release(control);
    }
done:
    if (sessions) IAudioSessionEnumerator_Release(sessions);
    if (manager) IAudioSessionManager2_Release(manager);
    if (device) IMMDevice_Release(device);
    if (enumerator) IMMDeviceEnumerator_Release(enumerator);
    return count;
}

#define S_MAX_SESSIONS 128

int nag_wasapi_audio_apps(unsigned *pids, char *exes, char *names, int *active,
                          int recordBytes, int max) {
    if (!pids || !exes || !names || !active || recordBytes <= 0 || max <= 0) return 0;
    int com = beginCOM();
    if (com < 0) return 0;
    SessionEntry *sessions = (SessionEntry *)calloc(S_MAX_SESSIONS, sizeof(SessionEntry));
    int count = 0;
    if (sessions) {
        int found = listSessions(sessions, S_MAX_SESSIONS);
        for (int i = 0; i < found && count < max; i++) {
            WCHAR path[MAX_PATH * 2];
            if (imagePath(sessions[i].pid, path, MAX_PATH * 2) != 0) continue;   // gone already
            WCHAR described[128];
            const WCHAR *name = sessions[i].display;
            if (!name[0]) name = describeExe(path, described, 128) == 0 ? described : fileNameOf(path);
            pids[count] = (unsigned)sessions[i].pid;
            toUtf8(fileNameOf(path), exes + (size_t)count * recordBytes, recordBytes);
            toUtf8(name, names + (size_t)count * recordBytes, recordBytes);
            active[count] = sessions[i].active;
            count++;
        }
        free(sessions);
    }
    if (com == 1) CoUninitialize();
    return count;
}

// MARK: - Finding a process

unsigned nag_wasapi_find_process(const char *exe) {
    if (!exe || !exe[0]) return 0;
    WCHAR wanted[MAX_PATH];
    if (MultiByteToWideChar(CP_UTF8, 0, exe, -1, wanted, MAX_PATH) <= 0) return 0;

    // Every process with this name, and each one's parent.
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return 0;
    enum { cap = 512 };
    DWORD *pidList = (DWORD *)malloc(cap * sizeof(DWORD));
    DWORD *parentList = (DWORD *)malloc(cap * sizeof(DWORD));
    int n = 0;
    DWORD own = GetCurrentProcessId();
    PROCESSENTRY32W entry;
    entry.dwSize = sizeof(entry);
    if (pidList && parentList && Process32FirstW(snapshot, &entry)) {
        do {
            if (entry.th32ProcessID != own && _wcsicmp(entry.szExeFile, wanted) == 0 && n < cap) {
                pidList[n] = entry.th32ProcessID;
                parentList[n] = entry.th32ParentProcessID;
                n++;
            }
        } while (Process32NextW(snapshot, &entry));
    }
    CloseHandle(snapshot);

    unsigned chosen = 0;
    if (n > 0) {
        // One with an audio session, if any has.
        int pick = -1;
        int com = beginCOM();
        if (com >= 0) {
            SessionEntry *sessions = (SessionEntry *)calloc(S_MAX_SESSIONS, sizeof(SessionEntry));
            if (sessions) {
                int found = listSessions(sessions, S_MAX_SESSIONS);
                // A playing session first, then any.
                for (int pass = 0; pass < 2 && pick < 0; pass++)
                    for (int s = 0; s < found && pick < 0; s++)
                        if (pass == 1 || sessions[s].active)
                            for (int i = 0; i < n; i++) if (pidList[i] == sessions[s].pid) { pick = i; break; }
                free(sessions);
            }
            if (com == 1) CoUninitialize();
        }
        if (pick < 0) pick = 0;
        // Up to its topmost ancestor of the same name, so the include covers the whole app —
        // browsers and many others play from a child process that can be restarted.
        for (int steps = 0; steps < 32; steps++) {
            int parent = -1;
            for (int i = 0; i < n; i++) if (pidList[i] == parentList[pick] && i != pick) { parent = i; break; }
            if (parent < 0) break;
            pick = parent;
        }
        chosen = (unsigned)pidList[pick];
    }
    free(pidList);
    free(parentList);
    return chosen;
}
