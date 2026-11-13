// The capture object's insides, shared by the two files that open one: NAGWASAPI.c,
// the default device's loopback, and NAGWASAPISources.c, process loopback and input devices.
// Not a public header: Swift sees only the handle.

#ifndef NAG_WASAPI_CAPTURE_H
#define NAG_WASAPI_CAPTURE_H

#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>

#include "NAGWASAPI.h"

struct NAGWasapiCapture {
    IMMDeviceEnumerator *enumerator;
    /// The endpoint being read, or for process loopback the default playback device — kept only
    /// for its name and ID, since a process loopback has no endpoint of its own.
    IMMDevice *device;
    IAudioClient *client;
    IAudioCaptureClient *capture;
    WAVEFORMATEX *mix;            // CoTaskMem; NULL when the format was chosen here
    HANDLE event;                 // process loopback is event-driven and will not start without one
    HANDLE target;                // the process loopback's target process, to notice it quit
    int kind;                     // NAG_SOURCE_*
    int rate;
    int channels;
    int bytesPerSample;
    int isFloat;
    int started;
    int comInitialised;
    WCHAR deviceID[256];
};

// Shared between the two files (NAGWASAPI.c defines them).
void nag_capture_say(char *error, int bytes, const char *what, HRESULT hr);
void nag_capture_release_all(NAGWasapiCapture *c);
int nag_capture_take_format(NAGWasapiCapture *c, char *error, int errorBytes);
int nag_capture_friendly_name(IMMDevice *device, char *name, int nameBytes);

#endif
