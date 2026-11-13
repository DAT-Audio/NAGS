// The plug-in instance behind `NAGVST3Plugin`, shared by the processing and editor sources.

#pragma once

#include "NAGVST3Internal.h"
#include "NAGVST3.h"

#include "pluginterfaces/base/funknownimpl.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivstmessage.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "pluginterfaces/vst/ivstprocesscontext.h"
#include "public.sdk/source/vst/hosting/connectionproxy.h"
#include "public.sdk/source/vst/hosting/module.h"

#include <atomic>
#include <mutex>
#include <vector>

namespace nagvst3 {

using namespace Steinberg;
using namespace Steinberg::Vst;

/// Reference counting for host objects handed to a plug-in, which may keep them.
#define NAG_VST3_REFCOUNT                                                                    \
    std::atomic<uint32> refs {1};                                                           \
    uint32 PLUGIN_API addRef() override { return ++refs; }                                  \
    uint32 PLUGIN_API release() override {                                                  \
        uint32 r = --refs;                                                                  \
        if (r == 0) delete this;                                                            \
        return r;                                                                           \
    }

/// One parameter's points for one block, fixed in size: the audio thread fills these and must
/// not allocate. Points past the capacity overwrite the last, which keeps the final value right.
class ParamQueue final : public IParamValueQueue {
public:
    static constexpr int32 kMaxPoints = 32;
    ParamID id = 0;
    int32 count = 0;
    int32 offsets[kMaxPoints] {};
    ParamValue values[kMaxPoints] {};

    tresult PLUGIN_API queryInterface(const TUID iid, void** obj) override {
        if (FUnknownPrivate::iidEqual(iid, IParamValueQueue::iid) || FUnknownPrivate::iidEqual(iid, FUnknown::iid)) {
            *obj = this;
            return kResultOk;
        }
        *obj = nullptr;
        return kNoInterface;
    }
    // Owned by the plug-in instance, never by whoever asks for it.
    uint32 PLUGIN_API addRef() override { return 1; }
    uint32 PLUGIN_API release() override { return 1; }

    ParamID PLUGIN_API getParameterId() override { return id; }
    int32 PLUGIN_API getPointCount() override { return count; }
    tresult PLUGIN_API getPoint(int32 index, int32& sampleOffset, ParamValue& value) override {
        if (index < 0 || index >= count) return kResultFalse;
        sampleOffset = offsets[index];
        value = values[index];
        return kResultOk;
    }
    tresult PLUGIN_API addPoint(int32 sampleOffset, ParamValue value, int32& index) override {
        if (count > 0 && (offsets[count - 1] == sampleOffset || count == kMaxPoints)) {
            values[count - 1] = value;
            index = count - 1;
            return kResultOk;
        }
        offsets[count] = sampleOffset;
        values[count] = value;
        index = count++;
        return kResultOk;
    }
};

/// The changes for one block, fixed in size, as `ParamQueue`.
class ParamChanges final : public IParameterChanges {
public:
    static constexpr int32 kMaxQueues = 128;
    ParamQueue queues[kMaxQueues];
    int32 used = 0;

    void clear() { used = 0; }

    tresult PLUGIN_API queryInterface(const TUID iid, void** obj) override {
        if (FUnknownPrivate::iidEqual(iid, IParameterChanges::iid) || FUnknownPrivate::iidEqual(iid, FUnknown::iid)) {
            *obj = this;
            return kResultOk;
        }
        *obj = nullptr;
        return kNoInterface;
    }
    uint32 PLUGIN_API addRef() override { return 1; }
    uint32 PLUGIN_API release() override { return 1; }

    int32 PLUGIN_API getParameterCount() override { return used; }
    IParamValueQueue* PLUGIN_API getParameterData(int32 index) override {
        return index >= 0 && index < used ? &queues[index] : nullptr;
    }
    IParamValueQueue* PLUGIN_API addParameterData(const ParamID& id, int32& index) override {
        for (int32 i = 0; i < used; ++i)
            if (queues[i].id == id) { index = i; return &queues[i]; }
        if (used == kMaxQueues) return nullptr;
        ParamQueue& q = queues[used];
        q.id = id;
        q.count = 0;
        index = used++;
        return &q;
    }
};

/// A single-producer, single-consumer ring of parameter values: no locks on either side.
struct ParamRing {
    static constexpr uint32_t kSize = 1024;
    struct Item { ParamID id; ParamValue value; };
    Item items[kSize];
    std::atomic<uint32_t> head {0}, tail {0};

    /// Drops the value when full: the ring is only full when nobody has been draining it.
    bool push(ParamID id, ParamValue value) {
        uint32_t h = head.load(std::memory_order_relaxed);
        if (h - tail.load(std::memory_order_acquire) >= kSize) return false;
        items[h % kSize] = {id, value};
        head.store(h + 1, std::memory_order_release);
        return true;
    }
    template <typename F> void drain(F&& f) {
        uint32_t t = tail.load(std::memory_order_relaxed);
        uint32_t h = head.load(std::memory_order_acquire);
        while (t != h) { f(items[t % kSize]); ++t; }
        tail.store(t, std::memory_order_release);
    }
};

class ComponentHandler;
class Editor;

} // namespace nagvst3

struct NAGVST3Plugin {
    std::string name;
    std::string path;
    VST3::Hosting::Module::Ptr module;
    Steinberg::IPtr<Steinberg::Vst::IComponent> component;
    Steinberg::IPtr<Steinberg::Vst::IAudioProcessor> processor;
    Steinberg::IPtr<Steinberg::Vst::IEditController> controller;
    bool singleComponent = false;
    Steinberg::IPtr<Steinberg::Vst::ConnectionProxy> componentProxy, controllerProxy;
    nagvst3::ComponentHandler* handler = nullptr;
    bool hasBypassParam = false;
    Steinberg::Vst::ParamID bypassParam = 0;

    // The configuration (UI thread writes, only while the audio thread is kept out).
    double sampleRate = 48000;
    int maxBlock = 0;
    int channels = 0;
    Steinberg::Vst::SpeakerArrangement arrangement = 0;
    int map[8] {};
    bool active = false;
    bool processingOn = false;
    /// What the audio thread checks first: configured, accepted and active.
    bool ready = false;

    std::atomic<bool> failed {false};
    std::atomic<uint32_t> restartFlags {0};

    /// Edits from the editor (`performEdit`) on their way to the next process call. The producer
    /// side is locked because a plug-in may edit from more than one thread; the consumer, the
    /// audio thread, never locks.
    nagvst3::ParamRing edits;
    std::mutex editProducer;
    /// The processor's own output parameter changes, on their way to the controller (UI thread).
    nagvst3::ParamRing outputs;

    nagvst3::ParamChanges inChanges, outChanges;
    Steinberg::Vst::ProcessContext context {};
    Steinberg::Vst::ProcessData data {};
    std::vector<Steinberg::Vst::AudioBusBuffers> inBuses, outBuses;
    std::vector<float*> inPointers, outPointers;
    std::vector<float> outScratch, silence, trash;
    int64_t position = 0;

    nagvst3::Editor* editor = nullptr;
};

namespace nagvst3 {

/// `IComponentHandler`: how the controller tells the host about edits and restarts.
class ComponentHandler final : public IComponentHandler {
public:
    explicit ComponentHandler(NAGVST3Plugin* owner) : owner(owner) {}
    NAGVST3Plugin* owner;

    tresult PLUGIN_API queryInterface(const TUID iid, void** obj) override {
        if (FUnknownPrivate::iidEqual(iid, IComponentHandler::iid) || FUnknownPrivate::iidEqual(iid, FUnknown::iid)) {
            addRef();
            *obj = static_cast<IComponentHandler*>(this);
            return kResultOk;
        }
        *obj = nullptr;
        return kNoInterface;
    }
    NAG_VST3_REFCOUNT

    tresult PLUGIN_API beginEdit(ParamID) override { return kResultOk; }
    tresult PLUGIN_API performEdit(ParamID id, ParamValue value) override {
        if (!owner) return kResultFalse;
        std::lock_guard<std::mutex> guard(owner->editProducer);
        owner->edits.push(id, value);
        return kResultOk;
    }
    tresult PLUGIN_API endEdit(ParamID) override { return kResultOk; }
    /// Remembered, and acted on by the owner from the UI thread: a restart deactivates the
    /// plug-in, which must not happen under the audio thread.
    tresult PLUGIN_API restartComponent(int32 flags) override {
        if (owner) owner->restartFlags.fetch_or((uint32_t)flags);
        return kResultOk;
    }
};

/// Closes the editor without calling into the plug-in's view if it has failed. Editor source.
void closeEditor(NAGVST3Plugin* plugin);

} // namespace nagvst3
