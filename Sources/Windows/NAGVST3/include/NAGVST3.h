// VST3 hosting for the Windows Grabber's inserts, as plain C.
//
// Steinberg's SDK is C++ and Swift on Windows cannot import C++ classes reliably, so everything
// the inserts need is behind this header: opaque handles, UTF-8 strings, malloc'd results freed
// with `nag_vst3_free`. The SDK itself (MIT since 3.8) is vendored under ../vst3sdk.
//
// Threads, as VST3 lays them down:
//   - scanning, loading, configuring, state, the editor: the UI thread (COM STA is fine);
//   - `nag_vst3_process`: the audio thread, and nothing else. It allocates nothing, takes no lock
//     that can block, and makes no COM call.
// The caller keeps `nag_vst3_configure`, `nag_vst3_restart` and `nag_vst3_unload` from running
// while `nag_vst3_process` is (the Swift chain does it with a try-lock on the audio side).

#ifndef NAG_VST3_H
#define NAG_VST3_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Everything returned as `char*` or `uint8_t*` is malloc'd here and freed with this.
void nag_vst3_free(void *pointer);

// MARK: - Scanning

/// The folder plug-ins are installed in: `%CommonProgramFiles%\VST3`, as UTF-8. Malloc'd.
char *nag_vst3_default_folder(void);

/// Every module under `folderUtf8` (NULL for the default folder), recursively: bundles (folders
/// named `*.vst3`, not descended into) and old single-file DLLs named `*.vst3`. One line per
/// module, `path<TAB>mtime`, where mtime is the binary's last write time in Unix seconds — the
/// cache key with the path. Malloc'd.
char *nag_vst3_find_modules(const char *folderUtf8);

/// Describes one module as one line of JSON:
///   {"path":…,"source":"moduleinfo"|"module","vendor":…,"error":…,
///    "classes":[{"cid":"32 hex","name":…,"vendor":…,"category":…,"subCategories":[…],"version":…}]}
/// `moduleinfo.json` is read when the bundle has one; otherwise the module is loaded, but only if
/// `allowLoad` is non-zero — **loading an unknown plug-in can crash the process**, so the app
/// does that in a child process (`nag-vst3-scan`). Malloc'd.
char *nag_vst3_describe_module(const char *pathUtf8, int allowLoad);

/// Runs `exeUtf8` with `argsUtf8` (may be NULL) as a child process **with no window**, writes
/// `stdinUtf8` to its standard input and closes it, and returns everything it wrote to standard
/// output. The child is killed if it writes nothing for `idleTimeoutMs`, and then `*timedOut` is
/// set; otherwise `*exitCode` gets its exit code. Malloc'd; NULL if it could not start.
char *nag_vst3_run_child(const char *exeUtf8, const char *argsUtf8, const char *stdinUtf8,
                         int idleTimeoutMs, int *exitCode, int *timedOut);

/// For a scanner child: no Windows error dialog when a plug-in crashes it, so the parent sees the
/// exit at once instead of a process waiting on a dialog nobody can see.
void nag_vst3_quiet_crashes(void);

// MARK: - One plug-in instance

typedef struct NAGVST3Plugin NAGVST3Plugin;

enum {
    NAG_VST3_OK = 0,
    /// The plug-in will not take this width. It is kept loaded but inactive, and is not processed.
    NAG_VST3_REFUSED = 1,
    NAG_VST3_ERROR = -1,
};

/// Loads the module at `pathUtf8` (shared with other instances of it), creates the class
/// `classIDHex` (32 hex digits, as the scan reports it), initialises its component and
/// controller and connects them. Not yet active: `nag_vst3_configure` does that. NULL on failure,
/// with a reason in `error`. UI thread.
NAGVST3Plugin *nag_vst3_load(const char *pathUtf8, const char *classIDHex,
                             char *error, int errorCapacity);

/// Closes the editor, deactivates, disconnects and releases. UI thread, never during process.
void nag_vst3_unload(NAGVST3Plugin *plugin);

/// The class name the factory gave, UTF-8, owned by the plug-in.
const char *nag_vst3_name(NAGVST3Plugin *plugin);

/// Negotiates `channels` (2, 4, 6 or 8) in and out on the main buses, sets up 32-bit real-time
/// processing at `sampleRate` with blocks of up to `maxBlock`, and activates. Returns
/// `NAG_VST3_OK`, `NAG_VST3_REFUSED` (it would not take the width; left inactive) or
/// `NAG_VST3_ERROR`. On OK, `channelMap[e]` (if not NULL, `channels` entries) is the VST3
/// channel the engine's channel `e` is given to. Deactivates first if active. UI thread.
int nag_vst3_configure(NAGVST3Plugin *plugin, double sampleRate, int maxBlock, int channels,
                       int *channelMap);

/// The speaker arrangement in use, as VST3's bit mask (0 if not configured).
uint64_t nag_vst3_arrangement(NAGVST3Plugin *plugin);

/// The latency the plug-in reports, in samples at the configured rate. UI thread.
int nag_vst3_latency(NAGVST3Plugin *plugin);

/// Processes `frames` of `numChannels` planar channels **in place**, in the engine's channel
/// order. Must be the configured width; longer than the maximum block is done in pieces. Returns
/// 0 when processed; non-zero when not (not active, wrong width, or the plug-in faulted — see
/// `nag_vst3_has_failed`), in which case the buffers are left as they were. Audio thread only.
int nag_vst3_process(NAGVST3Plugin *plugin, float *const *channels, int numChannels, int frames);

/// Non-zero once the plug-in has faulted inside `process` (an access violation, say). It is never
/// called again; the owner takes it out of the chain and should not call into it further.
int nag_vst3_has_failed(NAGVST3Plugin *plugin);

/// `IComponentHandler::restartComponent` flags received since the last call (VST3's
/// `RestartFlags`: 1 reload, 2 I/O changed, 4 parameter values changed, 8 latency changed…).
uint32_t nag_vst3_take_restart_flags(NAGVST3Plugin *plugin);

/// What `kLatencyChanged` and `kIoChanged` ask of a host: deactivate, renegotiate the same
/// configuration, reactivate. Returns as `nag_vst3_configure`. UI thread, never during process.
int nag_vst3_restart(NAGVST3Plugin *plugin, int *channelMap);

/// Tells the plug-in it is bypassed, through its bypass parameter if it has one, so it can stop
/// working while out of circuit. The host's bypass does not depend on it.
void nag_vst3_set_bypass(NAGVST3Plugin *plugin, int bypassed);

/// The plug-in's settings: component state then controller state, in one blob with lengths.
/// Malloc'd into `*data`; returns 0 on success. UI thread.
int nag_vst3_get_state(NAGVST3Plugin *plugin, uint8_t **data, int64_t *size);
/// Restores a blob from `nag_vst3_get_state`. Returns 0 on success. UI thread.
int nag_vst3_set_state(NAGVST3Plugin *plugin, const uint8_t *data, int64_t size);

// MARK: - Editor

/// Non-zero if the plug-in has an editor for Win32.
int nag_vst3_has_editor(NAGVST3Plugin *plugin);

/// Called on the UI thread when the editor window has closed, however it closed.
typedef void (*nag_vst3_editor_closed)(void *context);

/// Opens the plug-in's editor in its own top-level window, owned by `parentHWND` (may be NULL),
/// titled `titleUtf8`. If it is already open it is brought to the front. Returns 0 on success.
/// UI thread; the thread must run a message loop.
int nag_vst3_open_editor(NAGVST3Plugin *plugin, void *parentHWND, const char *titleUtf8,
                         nag_vst3_editor_closed onClosed, void *context);
/// Closes the editor if open (the callback is called). UI thread.
void nag_vst3_close_editor(NAGVST3Plugin *plugin);
/// The editor window, or NULL when closed.
void *nag_vst3_editor_window(NAGVST3Plugin *plugin);

#ifdef __cplusplus
}
#endif

#endif
