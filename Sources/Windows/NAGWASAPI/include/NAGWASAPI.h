// WASAPI loopback capture, and render, as plain C.
//
// Swift's WinSDK module does not carry mmdeviceapi.h or audioclient.h, so the COM calls live
// here and Swift sees a handle and four functions. Everything about *what to do* with the audio
// — pacing, silence, the stream — stays in Swift, in `WASAPILoopback.swift`.
//
// One capture object belongs to one thread: open it, read from it and close it all on the same
// thread. It calls `CoInitializeEx` for that thread itself.

#ifndef NAG_WASAPI_H
#define NAG_WASAPI_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct NAGWasapiCapture NAGWasapiCapture;

/// Opens loopback capture on the default playback device, in its own shared-mode mix format.
/// Writes the format into `sampleRate` and `channels`.
/// Returns NULL on failure, with the reason as UTF-8 in `error` (at most `errorBytes`, always
/// null-terminated).
NAGWasapiCapture *nag_wasapi_open(int *sampleRate, int *channels, char *error, int errorBytes);

/// Begins capturing. 0 on success, non-zero on failure.
int nag_wasapi_start(NAGWasapiCapture *capture);

/// Reads whatever the device has ready into `dest` as interleaved 32-bit float, at most
/// `maxFrames` frames. Returns the number of frames written — 0 when nothing was ready, which is
/// what silence looks like: loopback delivers nothing at all while no app is playing. -1 on a
/// device error, after which the caller should close and open again.
int nag_wasapi_read(NAGWasapiCapture *capture, float *dest, int maxFrames);

/// Stops capturing. The object can be started again.
void nag_wasapi_stop(NAGWasapiCapture *capture);

/// Stops if needed, releases everything, and frees the object.
void nag_wasapi_close(NAGWasapiCapture *capture);

/// The playback device's name, as UTF-8, into `buffer` (at most `bytes`, always
/// null-terminated). 0 on success.
int nag_wasapi_device_name(NAGWasapiCapture *capture, char *buffer, int bytes);

/// Whether the default playback device has changed since this capture was opened — the capture
/// should then be closed and opened again. 1 if it has, 0 if not or if it could not be told.
int nag_wasapi_default_changed(NAGWasapiCapture *capture);

/// The default playback device's name and mix format, without opening a capture — so a window can
/// say what it would copy before anything is being sent. `name` is UTF-8 and always
/// null-terminated. 0 on success.
int nag_wasapi_default_device(char *name, int nameBytes, int *sampleRate, int *channels);

// MARK: - Sources (NAGWASAPISources.c)
//
// What the Sender copies, as the Mac Sender's Source menu offers it: everything this PC plays
// less one process tree (so the Grabber's or Sender's own playback is not sent back out), one
// app's process tree alone, or one input device whole. Each opens the same capture object as
// `nag_wasapi_open`, read, started, stopped and closed by the same functions above.
//
// The process kinds use process loopback (Windows 10 2004, build 19041, and later). It has no mix
// format of its own, so it is opened as 32-bit float at the default playback device's mix rate.

/// The default playback device's loopback, as `nag_wasapi_open`. Everything, this app included.
#define NAG_SOURCE_DEFAULT_LOOPBACK 0
/// Only the audio of process `pid` and its children.
#define NAG_SOURCE_PROCESS_INCLUDE 1
/// Everything this PC plays except process `pid` and its children.
#define NAG_SOURCE_PROCESS_EXCLUDE 2
/// The capture endpoint `deviceID`, in its own shared-mode mix format.
#define NAG_SOURCE_INPUT 3

/// Opens a capture of `kind`. `deviceID` (UTF-8) is the input's endpoint ID, for
/// NAG_SOURCE_INPUT only; `pid` is the target process, for the process kinds only.
/// `wantChannels` is the width asked of a process loopback (0: the default device's own); the
/// others always open at their device's own. Writes the opened rate and channel count.
/// Returns NULL on failure, with the reason in `error`.
NAGWasapiCapture *nag_wasapi_open_source(int kind, const char *deviceID, unsigned pid,
                                         int wantChannels, int *sampleRate, int *channels,
                                         char *error, int errorBytes);

/// Whether process loopback can be asked for at all: Windows 10 build 19041 or later. 1 if so.
/// It can still be refused; the open says so.
int nag_wasapi_process_loopback_available(void);

/// For the process kinds: whether the target process has quit. 1 if it has. Holding the process
/// open is what makes this safe against Windows reusing the number for a new process.
int nag_wasapi_target_exited(NAGWasapiCapture *capture);

/// The active input (capture) devices: up to `max`, each ID and friendly name in a `recordBytes`
/// record of `ids` and `names` (UTF-8), and each mix width in `channels`. Returns how many.
/// Any thread.
int nag_wasapi_input_devices(char *ids, char *names, int *channels, int recordBytes, int max);

/// The processes with an audio session on the default playback device now, one entry per
/// process, skipping system sounds and this process: up to `max`, each PID in `pids`, exe file
/// name (e.g. "player.exe") in `exes`, display name in `names` (UTF-8, `recordBytes` records),
/// and in `active` whether the session is playing at this moment. Returns how many. Any thread.
int nag_wasapi_audio_apps(unsigned *pids, char *exes, char *names, int *active,
                          int recordBytes, int max);

/// A running process with this exe file name (UTF-8, any case), as the process to capture: one
/// with an audio session if several share the name, raised to its topmost ancestor of the same
/// name, so the whole app is one process tree. 0 if none is running. Any thread.
unsigned nag_wasapi_find_process(const char *exe);

/// This process's ID.
unsigned nag_wasapi_own_pid(void);

// MARK: - Render (the Windows Grabber; NAGWASAPIRender.c)
//
// Playback on the default device, **shared mode only, never exclusive**: exclusive mode skips the
// device's effects, Windows Sonic and Dolby Atmos for Headphones among them. Event-driven: the
// device says when it wants audio, so the device's clock paces the Grabber and nothing here
// sleeps on Windows' coarse timer.
//
// Opened as WAVEFORMATEXTENSIBLE, 32-bit float, at the device's own mix rate, with as many
// channels as the bus and the speaker mask that width means (stereo, quad, 5.1, 7.1 surround).
// Windows converts to the device's mix when they differ, and with spatial sound on it places a
// correctly labelled surround stream around the head.
//
// Like the capture, one render object belongs to one thread: open, wait, write and close it all on
// the same thread. Open also asks MMCSS to schedule that thread as audio ("Pro Audio").

typedef struct NAGWasapiRender NAGWasapiRender;

/// Opens the default playback device for `busChannels` channels of float.
/// Writes the device's mix rate and channel count, the width actually opened (`openedChannels`,
/// the same as asked unless the device refused it and stereo was used), the endpoint buffer in
/// frames, and the device's name and ID (UTF-8, always null-terminated).
/// Returns NULL on failure, with the reason in `error`.
NAGWasapiRender *nag_render_open(int busChannels, int *sampleRate, int *deviceChannels,
                                 int *openedChannels, int *bufferFrames,
                                 char *name, int nameBytes, char *deviceID, int idBytes,
                                 char *error, int errorBytes);

/// As `nag_render_open`, on a chosen device (its ID, UTF-8) rather than the default. A device that
/// is not connected falls back to the default, and `usedFallback` says so. NULL `wantedID` is the
/// default.
NAGWasapiRender *nag_render_open_device(const char *wantedID, int *usedFallback,
                                        int busChannels, int *sampleRate, int *deviceChannels,
                                        int *openedChannels, int *bufferFrames,
                                        char *name, int nameBytes, char *deviceID, int idBytes,
                                        char *error, int errorBytes);

/// The active playback devices: up to `max`, each ID and name in a `recordBytes` record of `ids`
/// and `names` (UTF-8), and each mix width in `channels`. Returns how many. Any thread.
int nag_render_devices(char *ids, char *names, int *channels, int recordBytes, int max);

/// Whether a device (by ID) is connected now. On the render's own thread.
int nag_render_device_active(NAGWasapiRender *render, const char *idUtf8);

/// Begins playback. 0 on success.
int nag_render_start(NAGWasapiRender *render);

/// Waits up to `timeoutMs` for the device to want audio. Returns how many frames it has room for
/// now (0 on a timeout), or -1 on a device error — the device went away or was reconfigured —
/// after which the caller should close and open again.
int nag_render_wait(NAGWasapiRender *render, int timeoutMs);

/// The device's buffer for `frames` frames of interleaved float, in the opened channel order.
/// NULL on a device error. Every successful call must be followed by `nag_render_release`.
float *nag_render_buffer(NAGWasapiRender *render, int frames);

/// Hands the frames written to the device. 0 on success, -1 on a device error.
int nag_render_release(NAGWasapiRender *render, int frames);

/// Stops if needed, releases everything, and frees the object.
void nag_render_close(NAGWasapiRender *render);

/// Whether the default playback device has changed since this render was opened. 1 if it has.
int nag_render_default_changed(NAGWasapiRender *render);

#ifdef __cplusplus
}
#endif

#endif
