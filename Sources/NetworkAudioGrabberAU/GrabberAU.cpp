// DAT Audio's network audio plugins as Audio Units (AUv2), on Apple's AudioUnitSDK (Apache-2.0;
// see Sources/AudioUnitSDK/LICENSE.txt). Three components, each doing one job:
//
//  - NAGReceiver, type `aumu` ("DAT Audio: Grabber"): an instrument that plays the Grabber's
//    mix — every stream it receives — on its track. Logic's software-instrument tracks,
//    REAPER's instrument FX, Live's MIDI tracks and the like.
//  - NAGReceiverEffect, type `aufx` ("DAT Audio: Grabber (effect)"): the Grabber plugin again, for
//    hosts that load only effects — Audacity, Audition, Premiere, Final Cut, Resolve, Audio
//    Hijack, Hindenburg. It puts the Grabber's mix in place of its input. Receive only, like
//    the instrument; kept on purpose.
//  - NAGSender, type `aufx` ("DAT Audio: Sender"): an effect that sends its track as VBAN, and
//    passes the track through (or, if chosen, silences it) in the host.
//
// Everything else — discovery, receivers, the mix, sending, the windows — is Swift
// (Sources/NetworkAudioGrabber/PluginBridge.swift), reached through the C functions below.

#include <AudioUnitSDK/AUEffectBase.h>
#include <AudioUnitSDK/MusicDeviceBase.h>
#include <AudioToolbox/AUCocoaUIView.h>
#include <atomic>
#include <cstring>

extern "C" {
// kind: 0 Grabber plugin, 1 Sender.
int32_t nag_au_open(int32_t kind);
void nag_au_close(int32_t handle);
void nag_au_configure(int32_t handle, int32_t kind, double rate, int32_t channels);
// Each Grabber plugin's own output (owned by the Swift side until the plugin closes), rendered from.
void* nag_au_receiver_output(int32_t handle);
void nag_au_render(void* output, AudioBufferList* abl, uint32_t frames) AUSDK_RTSAFE_TYPE;
// A Grabber plugin's latency in seconds (its streams' buffer), and the call that says it changed.
double nag_au_latency(int32_t handle);
void nag_au_on_latency(int32_t handle, void* context, void (*notify)(void*));
// Each Sender's own feed (owned by the Swift side until the plugin closes); its input — the
// track — goes in, and it says whether the track carries on to the output. Both real-time safe.
void* nag_au_sender_feed(int32_t handle);
void nag_au_send_input(void* feed, const AudioBufferList* abl, uint32_t frames) AUSDK_RTSAFE_TYPE;
int32_t nag_au_pass_through(void* feed) AUSDK_RTSAFE_TYPE;
// The plugin's copy in the DAW project (+1 retained, or null), and a project's copy handed back.
CFDataRef nag_au_save(int32_t handle);
void nag_au_restore(int32_t handle, CFDataRef data);
// The host's name for the Sender's track.
void nag_au_track_name(int32_t handle, CFStringRef name);
}

namespace {

const CFStringRef kBundleID = CFSTR("app.networkaudiograbber.au");
const CFStringRef kReceiverView = CFSTR("NAGReceiverViewFactory");
const CFStringRef kSenderView = CFSTR("NAGSenderViewFactory");

// The plugin's window: its own view, from this bundle.
OSStatus CocoaUIInfo(void* outData, CFStringRef viewClass)
{
	CFBundleRef bundle = CFBundleGetBundleWithIdentifier(kBundleID);
	if (bundle == nullptr) { return kAudioUnitErr_InvalidProperty; }
	auto* info = static_cast<AudioUnitCocoaViewInfo*>(outData);
	info->mCocoaAUViewBundleLocation = CFBundleCopyBundleURL(bundle); // host releases
	info->mCocoaAUViewClass[0] = CFStringCreateCopy(nullptr, viewClass); // host releases
	return noErr;
}

void Configure(ausdk::AUBase& unit, int32_t handle, int32_t kind)
{
	const auto fmt = unit.Output(0).GetStreamFormat();
	nag_au_configure(handle, kind, fmt.mSampleRate, static_cast<int32_t>(fmt.mChannelsPerFrame));
}

// A private property (the range Apple leaves to plugins): the plugin's handle, for its window.
constexpr AudioUnitPropertyID kHandleProperty = 64000;
// The key our own state goes under in the host's saved dictionary.
const CFStringRef kStateKey = CFSTR("DAT Audio state");

// Adds the Swift side's copy to what the SDK saved (parameters, version, codes).
OSStatus AddState(CFPropertyListRef* outData, int32_t handle)
{
	CFDataRef ours = nag_au_save(handle);
	if (ours == nullptr) { return noErr; }
	CFMutableDictionaryRef copy = CFDictionaryCreateMutableCopy(nullptr, 0, static_cast<CFDictionaryRef>(*outData));
	CFDictionarySetValue(copy, kStateKey, ours);
	CFRelease(ours);
	CFRelease(*outData);
	*outData = copy;
	return noErr;
}

void TakeState(CFPropertyListRef plist, int32_t handle)
{
	if (plist == nullptr || CFGetTypeID(plist) != CFDictionaryGetTypeID()) { return; }
	const void* ours = CFDictionaryGetValue(static_cast<CFDictionaryRef>(plist), kStateKey);
	if (ours != nullptr && CFGetTypeID(ours) == CFDataGetTypeID()) {
		nag_au_restore(handle, static_cast<CFDataRef>(ours));
	}
}

// The handle property's info and value; false if `id` is not it.
bool HandleInfo(AudioUnitPropertyID id, AudioUnitScope scope, UInt32& size, bool& writable)
{
	if (id != kHandleProperty || scope != kAudioUnitScope_Global) { return false; }
	size = sizeof(int32_t);
	writable = false;
	return true;
}
bool HandleValue(AudioUnitPropertyID id, AudioUnitScope scope, void* data, int32_t handle)
{
	if (id != kHandleProperty || scope != kAudioUnitScope_Global) { return false; }
	*static_cast<int32_t*>(data) = handle;
	return true;
}

} // namespace

// -------------------------------------------------------------------------------------------------

// What both Grabber plugins share: their own output, and the latency the host is told — kept here, so
// GetLatency (which must be real-time safe) only reads an atomic.
struct ReceiverLink {
	int32_t handle;
	void* output;
	std::atomic<double> latency{ 0 };
	ausdk::AUBase* unit;

	ReceiverLink(ausdk::AUBase* u) : handle{ nag_au_open(0) }, output{ nag_au_receiver_output(handle) }, unit{ u }
	{
		nag_au_on_latency(handle, this, &Changed);
	}
	// On the main thread, when the playing streams or their buffer change.
	static void Changed(void* context)
	{
		auto* link = static_cast<ReceiverLink*>(context);
		link->latency = nag_au_latency(link->handle);
		link->unit->PropertyChanged(kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0);
	}
	void Render(AudioBufferList* abl, UInt32 frames) AUSDK_RTSAFE
	{
		if (output != nullptr) {
			nag_au_render(output, abl, frames);
			return;
		}
		for (UInt32 b = 0; b < abl->mNumberBuffers; ++b) {
			if (abl->mBuffers[b].mData != nullptr) { std::memset(abl->mBuffers[b].mData, 0, abl->mBuffers[b].mDataByteSize); }
		}
	}
};

class NAGReceiver : public ausdk::MusicDeviceBase {
	using Base = ausdk::MusicDeviceBase;
	ReceiverLink mLink{ this };
	int32_t mHandle = mLink.handle;

public:
	explicit NAGReceiver(AudioComponentInstance ci) : Base{ ci, 0, 1 } {}
	Float64 GetLatency() AUSDK_RTSAFE override { return mLink.latency; }
	~NAGReceiver() override { nag_au_close(mHandle); }

	OSStatus Initialize() override
	{
		if (const OSStatus s = Base::Initialize(); s != noErr) { return s; }
		Configure(*this, mHandle, 0);
		mLink.latency = nag_au_latency(mHandle);
		return noErr;
	}

	bool StreamFormatWritable(AudioUnitScope, AudioUnitElement) override { return true; }
	bool CanScheduleParameters() const noexcept AUSDK_RTSAFE override { return false; }
	bool SupportsTail() AUSDK_RTSAFE override { return true; }

	// Notes are accepted and ignored: an instrument slot sends them, and this plays the network.
	OSStatus HandleNoteOn(UInt8, UInt8, UInt8, UInt32) AUSDK_RTSAFE override { return noErr; }
	OSStatus HandleNoteOff(UInt8, UInt8, UInt8, UInt32) AUSDK_RTSAFE override { return noErr; }

	UInt32 SupportedNumChannels(const AUChannelInfo** outInfo) override
	{
		static const AUChannelInfo info[] = { { 0, 2 }, { 0, 1 } };
		if (outInfo != nullptr) { *outInfo = info; }
		return 2;
	}

	OSStatus Render(AudioUnitRenderActionFlags& flags, const AudioTimeStamp&, UInt32 frames) AUSDK_RTSAFE override
	{
		mLink.Render(&Output(0).GetBufferList(), frames);
		flags &= ~kAudioUnitRenderAction_OutputIsSilence;
		return noErr;
	}

	OSStatus GetPropertyInfo(AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement el,
		UInt32& size, bool& writable) override
	{
		if (scope == kAudioUnitScope_Global && id == kAudioUnitProperty_CocoaUI) {
			size = sizeof(AudioUnitCocoaViewInfo);
			writable = false;
			return noErr;
		}
		if (HandleInfo(id, scope, size, writable)) { return noErr; }
		return Base::GetPropertyInfo(id, scope, el, size, writable);
	}

	OSStatus GetProperty(AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement el, void* data) override
	{
		if (scope == kAudioUnitScope_Global && id == kAudioUnitProperty_CocoaUI) { return CocoaUIInfo(data, kReceiverView); }
		if (HandleValue(id, scope, data, mHandle)) { return noErr; }
		return Base::GetProperty(id, scope, el, data);
	}

	// The DAW project keeps the plugin's own copy beside the SDK's.
	OSStatus SaveState(CFPropertyListRef* outData) override
	{
		if (const OSStatus s = Base::SaveState(outData); s != noErr) { return s; }
		return AddState(outData, mHandle);
	}

	OSStatus RestoreState(CFPropertyListRef plist) override
	{
		if (const OSStatus s = Base::RestoreState(plist); s != noErr) { return s; }
		TakeState(plist, mHandle);
		return noErr;
	}
};

AUSDK_COMPONENT_ENTRY(ausdk::AUMusicDeviceFactory, NAGReceiver)

// -------------------------------------------------------------------------------------------------

// The Grabber plugin for effect-only hosts: same engine and window as the instrument; the input
// is not used, and the output is the Grabber's mix.
class NAGReceiverEffect : public ausdk::AUEffectBase {
	using Base = ausdk::AUEffectBase;
	ReceiverLink mLink{ this };
	int32_t mHandle = mLink.handle;

public:
	explicit NAGReceiverEffect(AudioComponentInstance ci) : Base{ ci, false } {}
	Float64 GetLatency() AUSDK_RTSAFE override { return mLink.latency; }
	~NAGReceiverEffect() override { nag_au_close(mHandle); }

	OSStatus Initialize() override
	{
		if (const OSStatus s = Base::Initialize(); s != noErr) { return s; }
		Configure(*this, mHandle, 0);
		mLink.latency = nag_au_latency(mHandle);
		return noErr;
	}

	bool SupportsTail() AUSDK_RTSAFE override { return true; }

	UInt32 SupportedNumChannels(const AUChannelInfo** outInfo) override
	{
		static const AUChannelInfo info[] = { { 2, 2 }, { 1, 1 } };
		if (outInfo != nullptr) { *outInfo = info; }
		return 2;
	}

	OSStatus ProcessBufferLists(AudioUnitRenderActionFlags& flags, const AudioBufferList&,
		AudioBufferList& out, UInt32 frames) AUSDK_RTSAFE override
	{
		mLink.Render(&out, frames);
		// A silent input marks the output silent too, and the host then skips it: this output
		// is the network, not the input, so it is never marked silent.
		flags &= ~kAudioUnitRenderAction_OutputIsSilence;
		return noErr;
	}

	OSStatus GetPropertyInfo(AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement el,
		UInt32& size, bool& writable) override
	{
		if (scope == kAudioUnitScope_Global && id == kAudioUnitProperty_CocoaUI) {
			size = sizeof(AudioUnitCocoaViewInfo);
			writable = false;
			return noErr;
		}
		if (HandleInfo(id, scope, size, writable)) { return noErr; }
		return Base::GetPropertyInfo(id, scope, el, size, writable);
	}

	OSStatus GetProperty(AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement el, void* data) override
	{
		if (scope == kAudioUnitScope_Global && id == kAudioUnitProperty_CocoaUI) { return CocoaUIInfo(data, kReceiverView); }
		if (HandleValue(id, scope, data, mHandle)) { return noErr; }
		return Base::GetProperty(id, scope, el, data);
	}

	// The DAW project keeps the plugin's own copy beside the SDK's.
	OSStatus SaveState(CFPropertyListRef* outData) override
	{
		if (const OSStatus s = Base::SaveState(outData); s != noErr) { return s; }
		return AddState(outData, mHandle);
	}

	OSStatus RestoreState(CFPropertyListRef plist) override
	{
		if (const OSStatus s = Base::RestoreState(plist); s != noErr) { return s; }
		TakeState(plist, mHandle);
		return noErr;
	}
};

AUSDK_COMPONENT_ENTRY(ausdk::AUBaseFactory, NAGReceiverEffect)

// -------------------------------------------------------------------------------------------------

class NAGSender : public ausdk::AUEffectBase {
	using Base = ausdk::AUEffectBase;
	int32_t mHandle;
	void* mFeed; // this Sender's own, from the Swift side; valid until nag_au_close

public:
	explicit NAGSender(AudioComponentInstance ci)
		: Base{ ci, false }, mHandle{ nag_au_open(1) }, mFeed{ nag_au_sender_feed(mHandle) } {}
	~NAGSender() override { nag_au_close(mHandle); }

	OSStatus Initialize() override
	{
		if (const OSStatus s = Base::Initialize(); s != noErr) { return s; }
		Configure(*this, mHandle, 1);
		return noErr;
	}

	bool SupportsTail() AUSDK_RTSAFE override { return true; }

	UInt32 SupportedNumChannels(const AUChannelInfo** outInfo) override
	{
		static const AUChannelInfo info[] = { { 2, 2 }, { 1, 1 } };
		if (outInfo != nullptr) { *outInfo = info; }
		return 2;
	}

	// The host naming the track: the stream is named after it, until renamed.
	void PropertyChanged(AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement el) override
	{
		if (id == kAudioUnitProperty_ContextName && GetContextName() != nullptr) {
			nag_au_track_name(mHandle, GetContextName());
		}
		Base::PropertyChanged(id, scope, el);
	}

	// The track is sent (while Send is on), then passed on to the output — or silenced, when
	// "Pass the track through while sending" is off and something is being sent.
	OSStatus ProcessBufferLists(AudioUnitRenderActionFlags& flags, const AudioBufferList& in,
		AudioBufferList& out, UInt32 frames) AUSDK_RTSAFE override
	{
		if (mFeed != nullptr) { nag_au_send_input(mFeed, &in, frames); }
		const bool pass = mFeed == nullptr || nag_au_pass_through(mFeed) != 0;
		for (UInt32 b = 0; b < out.mNumberBuffers; ++b) {
			auto* dst = out.mBuffers[b].mData;
			if (dst == nullptr) { continue; }
			const void* src = b < in.mNumberBuffers ? in.mBuffers[b].mData : nullptr;
			const UInt32 bytes = frames * sizeof(float);
			if (pass && src != nullptr) {
				if (src != dst) { std::memcpy(dst, src, bytes); }
			} else {
				std::memset(dst, 0, bytes);
			}
		}
		if (!pass) { flags |= kAudioUnitRenderAction_OutputIsSilence; }
		return noErr;
	}

	OSStatus GetPropertyInfo(AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement el,
		UInt32& size, bool& writable) override
	{
		if (scope == kAudioUnitScope_Global && id == kAudioUnitProperty_CocoaUI) {
			size = sizeof(AudioUnitCocoaViewInfo);
			writable = false;
			return noErr;
		}
		if (HandleInfo(id, scope, size, writable)) { return noErr; }
		return Base::GetPropertyInfo(id, scope, el, size, writable);
	}

	OSStatus GetProperty(AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement el, void* data) override
	{
		if (scope == kAudioUnitScope_Global && id == kAudioUnitProperty_CocoaUI) { return CocoaUIInfo(data, kSenderView); }
		if (HandleValue(id, scope, data, mHandle)) { return noErr; }
		return Base::GetProperty(id, scope, el, data);
	}

	// The DAW project keeps the plugin's own copy beside the SDK's.
	OSStatus SaveState(CFPropertyListRef* outData) override
	{
		if (const OSStatus s = Base::SaveState(outData); s != noErr) { return s; }
		return AddState(outData, mHandle);
	}

	OSStatus RestoreState(CFPropertyListRef plist) override
	{
		if (const OSStatus s = Base::RestoreState(plist); s != noErr) { return s; }
		TakeState(plist, mHandle);
		return noErr;
	}
};

AUSDK_COMPONENT_ENTRY(ausdk::AUBaseFactory, NAGSender)
