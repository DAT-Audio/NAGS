// Loading, configuring, processing and the state of one VST3 effect (NAGVST3.h).

#include "NAGVST3PluginImpl.h"

#include "pluginterfaces/vst/vstspeaker.h"
#include "public.sdk/source/common/memorystream.h"
#include "public.sdk/source/vst/hosting/hostclasses.h"

#include <xmmintrin.h>

#include <map>
#include <memory>

using namespace nagvst3;
using namespace Steinberg;
using namespace Steinberg::Vst;

namespace {

/// One host object for every plug-in: what `initialize` is given as its context, and what makes
/// the messages and attribute lists a separate controller talks to its component with.
FUnknown* hostContext() {
    static HostApplication* host = new HostApplication();   // for the life of the process
    return host;
}

/// Modules shared between instances. Each `Module` calls the DLL's `ExitDll` when it goes, so two
/// of them for one DLL would shut it down under the instance still using it.
std::mutex modulesLock;
std::map<std::string, std::weak_ptr<VST3::Hosting::Module>> modules;

VST3::Hosting::Module::Ptr sharedModule(const std::string& path, std::string& error) {
    std::lock_guard<std::mutex> guard(modulesLock);
    if (auto existing = modules[path].lock()) return existing;
    auto module = VST3::Hosting::Module::create(path, error);
    if (module) modules[path] = module;
    return module;
}

/// The arrangements tried for each width, best first, and for each the VST3 speaker the engine's
/// channels go to, in the engine's SMPTE order:
///   2.0  L R                       → kStereo         L R
///   4.0  L R Ls Rs                 → k40Music        L R Ls Rs
///   5.1  L R C LFE Ls Rs           → k51             L R C Lfe Ls Rs
///   7.1  L R C LFE Lss Rss Lrs Rrs → k71Music        L R C Lfe Ls Rs Sl Sr (Ls/Rs are the rears,
///                                                    Sl/Sr the sides: ITU 0+7+0.1)
///                                  → k71CineFullRear L R C Lfe Ls Rs Lcs Rcs (sides as Ls/Rs)
/// VST3 orders a bus's channels by speaker bit, lowest first.
struct Layout { SpeakerArrangement arrangement; Speaker speakers[8]; };

const Layout layouts2[] = {{SpeakerArr::kStereo, {kSpeakerL, kSpeakerR}}};
const Layout layouts4[] = {{SpeakerArr::k40Music, {kSpeakerL, kSpeakerR, kSpeakerLs, kSpeakerRs}}};
const Layout layouts6[] = {{SpeakerArr::k51, {kSpeakerL, kSpeakerR, kSpeakerC, kSpeakerLfe, kSpeakerLs, kSpeakerRs}}};
const Layout layouts8[] = {
    {SpeakerArr::k71Music, {kSpeakerL, kSpeakerR, kSpeakerC, kSpeakerLfe, kSpeakerSl, kSpeakerSr, kSpeakerLs, kSpeakerRs}},
    {SpeakerArr::k71CineFullRear, {kSpeakerL, kSpeakerR, kSpeakerC, kSpeakerLfe, kSpeakerLs, kSpeakerRs, kSpeakerLcs, kSpeakerRcs}},
};

int channelIndex(SpeakerArrangement arrangement, Speaker speaker) {
    return (int)__builtin_popcountll(arrangement & (speaker - 1));
}

int channelCount(SpeakerArrangement arrangement) { return (int)__builtin_popcountll(arrangement); }

void deactivate(NAGVST3Plugin* p) {
    p->ready = false;
    if (p->failed.load()) return;
    if (p->processingOn) p->processor->setProcessing(false);
    p->processingOn = false;
    if (p->active) p->component->setActive(false);
    p->active = false;
}

/// Everything the audio thread will touch, made here so it never has to allocate.
void prepareBuffers(NAGVST3Plugin* p) {
    int32 inCount = p->component->getBusCount(kAudio, kInput);
    int32 outCount = p->component->getBusCount(kAudio, kOutput);
    std::vector<int> inChannels(inCount), outChannels(outCount);
    size_t inTotal = 0, outTotal = 0;
    for (int32 i = 0; i < inCount; ++i) {
        SpeakerArrangement a = 0;
        p->processor->getBusArrangement(kInput, i, a);
        inChannels[i] = i == 0 ? p->channels : channelCount(a);
        inTotal += inChannels[i];
    }
    for (int32 i = 0; i < outCount; ++i) {
        SpeakerArrangement a = 0;
        p->processor->getBusArrangement(kOutput, i, a);
        outChannels[i] = i == 0 ? p->channels : channelCount(a);
        outTotal += outChannels[i];
    }
    size_t block = (size_t)p->maxBlock;
    p->outScratch.assign(block * p->channels, 0.f);
    p->silence.assign(block, 0.f);
    p->trash.assign(block, 0.f);
    p->inPointers.assign(inTotal, p->silence.data());
    p->outPointers.assign(outTotal, p->trash.data());
    p->inBuses.assign(inCount, AudioBusBuffers {});
    p->outBuses.assign(outCount, AudioBusBuffers {});
    size_t at = 0;
    for (int32 i = 0; i < inCount; ++i) {
        p->inBuses[i].numChannels = inChannels[i];
        p->inBuses[i].channelBuffers32 = p->inPointers.data() + at;
        at += inChannels[i];
    }
    at = 0;
    for (int32 i = 0; i < outCount; ++i) {
        p->outBuses[i].numChannels = outChannels[i];
        p->outBuses[i].channelBuffers32 = p->outPointers.data() + at;
        at += outChannels[i];
    }
    // The main output's channels are our scratch, never the engine's planes: some plug-ins do
    // not cope with in and out being the same memory, and the copy back is cheap.
    for (int c = 0; c < p->channels; ++c) p->outPointers[c] = p->outScratch.data() + block * c;

    p->context = ProcessContext {};
    p->context.sampleRate = p->sampleRate;
    p->context.tempo = 120;
    p->context.timeSigNumerator = 4;
    p->context.timeSigDenominator = 4;
    // Audio runs continuously, so to a plug-in it is playing: some meters and analysers only
    // run while the transport does.
    p->context.state = ProcessContext::kPlaying | ProcessContext::kTempoValid |
                       ProcessContext::kTimeSigValid | ProcessContext::kContTimeValid;

    p->data = ProcessData {};
    p->data.processMode = kRealtime;
    p->data.symbolicSampleSize = kSample32;
    p->data.numInputs = inCount;
    p->data.numOutputs = outCount;
    p->data.inputs = p->inBuses.data();
    p->data.outputs = p->outBuses.data();
    p->data.inputParameterChanges = &p->inChanges;
    p->data.outputParameterChanges = &p->outChanges;
    p->data.processContext = &p->context;
}

int configure(NAGVST3Plugin* p, double sampleRate, int maxBlock, int channels, int* channelMap) {
    if (p->failed.load()) return NAG_VST3_ERROR;
    deactivate(p);
    p->sampleRate = sampleRate;
    p->maxBlock = std::max(1, maxBlock);
    p->channels = channels;
    p->arrangement = 0;

    const Layout* layouts = nullptr;
    size_t layoutCount = 0;
    switch (channels) {
    case 2: layouts = layouts2; layoutCount = 1; break;
    case 4: layouts = layouts4; layoutCount = 1; break;
    case 6: layouts = layouts6; layoutCount = 1; break;
    case 8: layouts = layouts8; layoutCount = 2; break;
    default: return NAG_VST3_REFUSED;
    }

    int32 inCount = p->component->getBusCount(kAudio, kInput);
    int32 outCount = p->component->getBusCount(kAudio, kOutput);
    if (inCount < 1 || outCount < 1) return NAG_VST3_REFUSED;    // not an insert effect
    std::vector<SpeakerArrangement> ins(inCount), outs(outCount);
    for (int32 i = 0; i < inCount; ++i) p->processor->getBusArrangement(kInput, i, ins[i]);
    for (int32 i = 0; i < outCount; ++i) p->processor->getBusArrangement(kOutput, i, outs[i]);

    // Asked, then checked: a plug-in may answer false and adopt it anyway, or answer true and
    // keep something else. What it reports afterwards is what it will process.
    const Layout* chosen = nullptr;
    for (size_t l = 0; l < layoutCount && !chosen; ++l) {
        ins[0] = outs[0] = layouts[l].arrangement;
        p->processor->setBusArrangements(ins.data(), inCount, outs.data(), outCount);
        SpeakerArrangement gotIn = 0, gotOut = 0;
        p->processor->getBusArrangement(kInput, 0, gotIn);
        p->processor->getBusArrangement(kOutput, 0, gotOut);
        if (gotIn == layouts[l].arrangement && gotOut == layouts[l].arrangement) chosen = &layouts[l];
    }
    if (!chosen) return NAG_VST3_REFUSED;    // no silent front-pair processing
    p->arrangement = chosen->arrangement;
    for (int e = 0; e < channels; ++e) p->map[e] = channelIndex(chosen->arrangement, chosen->speakers[e]);
    if (channelMap) for (int e = 0; e < channels; ++e) channelMap[e] = p->map[e];

    // The main buses on; side-chains and the like off (given silence and somewhere to write).
    for (int32 i = 0; i < inCount; ++i) p->component->activateBus(kAudio, kInput, i, i == 0);
    for (int32 i = 0; i < outCount; ++i) p->component->activateBus(kAudio, kOutput, i, i == 0);
    int32 eventIns = p->component->getBusCount(kEvent, kInput);
    for (int32 i = 0; i < eventIns; ++i) p->component->activateBus(kEvent, kInput, i, false);

    ProcessSetup setup {kRealtime, kSample32, p->maxBlock, sampleRate};
    if (p->processor->setupProcessing(setup) != kResultOk) return NAG_VST3_ERROR;
    prepareBuffers(p);
    tresult activated = p->component->setActive(true);
    if (activated != kResultOk && activated != kNotImplemented) return NAG_VST3_ERROR;
    p->active = true;
    p->processor->setProcessing(true);     // several answer kNotImplemented; that is fine
    p->processingOn = true;
    p->position = 0;
    p->ready = true;
    return NAG_VST3_OK;
}

/// The plug-in's `process`, inside a structured exception handler: a plug-in that faults takes
/// itself out rather than the app. No C++ objects with destructors may live in this function.
int guardedProcess(IAudioProcessor* processor, ProcessData* data, tresult* result) {
    __try {
        *result = processor->process(*data);
        return 0;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return 1;
    }
}

void releaseAll(NAGVST3Plugin* p) {
    closeEditor(p);
    if (!p->failed.load()) {
        deactivate(p);
        if (p->componentProxy) p->componentProxy->disconnect();
        if (p->controllerProxy) p->controllerProxy->disconnect();
        if (p->controller) p->controller->setComponentHandler(nullptr);
        if (p->controller && !p->singleComponent) p->controller->terminate();
        if (p->component) p->component->terminate();
        p->componentProxy = nullptr;
        p->controllerProxy = nullptr;
        p->controller = nullptr;
        p->processor = nullptr;
        p->component = nullptr;
        if (p->handler) { p->handler->owner = nullptr; p->handler->release(); }
        p->handler = nullptr;
        std::lock_guard<std::mutex> guard(modulesLock);
        p->module.reset();
        delete p;
    } else {
        // A plug-in that faulted is not called again, not even to be released: its objects and
        // its module are left as they are, which costs some memory and avoids a second fault.
        if (p->handler) p->handler->owner = nullptr;
        p->component.take();
        p->processor.take();
        p->controller.take();
        p->componentProxy.take();
        p->controllerProxy.take();
        new VST3::Hosting::Module::Ptr(std::move(p->module));
        delete p;
    }
}

} // namespace

extern "C" void nag_vst3_free(void* pointer) { free(pointer); }

extern "C" NAGVST3Plugin* nag_vst3_load(const char* pathUtf8, const char* classIDHex, char* error, int errorCapacity) {
    std::string path = pathUtf8 ? pathUtf8 : "";
    auto uid = VST3::UID::fromString(std::string(classIDHex ? classIDHex : ""));
    if (!uid) {
        copyError(error, errorCapacity, "not a class ID");
        return nullptr;
    }
    std::string why;
    auto module = sharedModule(path, why);
    if (!module) {
        copyError(error, errorCapacity, why.empty() ? "the module would not load" : why);
        return nullptr;
    }

    auto p = new NAGVST3Plugin();
    p->path = path;
    p->module = module;
    auto fail = [&](const std::string& text) -> NAGVST3Plugin* {
        copyError(error, errorCapacity, text);
        releaseAll(p);
        return nullptr;
    };

    const auto& factory = module->getFactory();
    factory.setHostContext(hostContext());
    for (const auto& info : factory.classInfos())
        if (info.ID() == *uid) p->name = info.name();
    if (p->name.empty()) return fail("the module has no such class");

    p->component = factory.createInstance<IComponent>(*uid);
    if (!p->component) return fail("the plug-in could not be created");
    if (p->component->initialize(hostContext()) != kResultOk) {
        p->component = nullptr;
        return fail("the plug-in would not initialise");
    }
    p->processor = U::cast<IAudioProcessor>(p->component.get());
    if (!p->processor) return fail("not an audio processor");
    if (p->processor->canProcessSampleSize(kSample32) != kResultTrue) return fail("does not process 32-bit float");

    // The controller: the component itself (a single-component effect), or a separate class.
    if (auto c = U::cast<IEditController>(p->component.get())) {
        p->controller = c;
        p->singleComponent = true;
    } else {
        TUID cid;
        if (p->component->getControllerClassId(cid) == kResultTrue) {
            p->controller = factory.createInstance<IEditController>(VST3::UID::fromTUID(cid));
            if (p->controller && p->controller->initialize(hostContext()) != kResultOk) p->controller = nullptr;
        }
    }

    p->handler = new ComponentHandler(p);
    if (p->controller) {
        p->controller->setComponentHandler(p->handler);
        if (!p->singleComponent) {
            // Through proxies, as the SDK's own host does, so either side can be disconnected
            // cleanly whatever the other does.
            auto componentPoint = U::cast<IConnectionPoint>(p->component.get());
            auto controllerPoint = U::cast<IConnectionPoint>(p->controller.get());
            if (componentPoint && controllerPoint) {
                p->componentProxy = owned(new ConnectionProxy(componentPoint));
                p->controllerProxy = owned(new ConnectionProxy(controllerPoint));
                p->componentProxy->connect(controllerPoint);
                p->controllerProxy->connect(componentPoint);
            }
        }
        // The controller starts from the component's state, so the two agree.
        MemoryStream stream;
        if (p->component->getState(&stream) == kResultOk) {
            stream.seek(0, IBStream::kIBSeekSet, nullptr);
            p->controller->setComponentState(&stream);
        }
        int32 count = p->controller->getParameterCount();
        for (int32 i = 0; i < count; ++i) {
            ParameterInfo info {};
            if (p->controller->getParameterInfo(i, info) == kResultOk && (info.flags & ParameterInfo::kIsBypass)) {
                p->hasBypassParam = true;
                p->bypassParam = info.id;
                break;
            }
        }
    }
    return p;
}

extern "C" void nag_vst3_unload(NAGVST3Plugin* p) {
    if (p) releaseAll(p);
}

extern "C" const char* nag_vst3_name(NAGVST3Plugin* p) { return p ? p->name.c_str() : ""; }

extern "C" int nag_vst3_configure(NAGVST3Plugin* p, double sampleRate, int maxBlock, int channels, int* channelMap) {
    if (!p) return NAG_VST3_ERROR;
    return configure(p, sampleRate, maxBlock, channels, channelMap);
}

extern "C" int nag_vst3_restart(NAGVST3Plugin* p, int* channelMap) {
    if (!p || p->channels == 0) return NAG_VST3_ERROR;
    return configure(p, p->sampleRate, p->maxBlock, p->channels, channelMap);
}

extern "C" uint64_t nag_vst3_arrangement(NAGVST3Plugin* p) { return p && p->ready ? p->arrangement : 0; }

extern "C" int nag_vst3_latency(NAGVST3Plugin* p) {
    if (!p || p->failed.load() || !p->processor) return 0;
    return (int)p->processor->getLatencySamples();
}

extern "C" int nag_vst3_has_failed(NAGVST3Plugin* p) { return p && p->failed.load() ? 1 : 0; }

extern "C" uint32_t nag_vst3_take_restart_flags(NAGVST3Plugin* p) { return p ? p->restartFlags.exchange(0) : 0; }

extern "C" int nag_vst3_process(NAGVST3Plugin* p, float* const* channels, int numChannels, int frames) {
    if (!p || !p->ready || p->failed.load(std::memory_order_relaxed) || numChannels != p->channels) return 1;
    if (frames <= 0) return 0;

    // The editor's edits since the last block, all at its start.
    p->inChanges.clear();
    p->edits.drain([p](const ParamRing::Item& item) {
        int32 index = 0;
        if (auto q = p->inChanges.addParameterData(item.id, index)) q->addPoint(0, item.value, index);
    });

    // Denormals flushed while the plug-in runs, as hosts do; the caller's mode is put back.
    unsigned int mxcsr = _mm_getcsr();
    _mm_setcsr(mxcsr | 0x8040);

    int status = 0;
    float** mainIn = p->inBuses[0].channelBuffers32;
    float** mainOut = p->outBuses[0].channelBuffers32;
    for (int done = 0; done < frames;) {
        int piece = std::min(frames - done, p->maxBlock);
        for (int e = 0; e < numChannels; ++e) mainIn[p->map[e]] = channels[e] + done;
        if (p->data.numInputs > 1) memset(p->silence.data(), 0, sizeof(float) * piece);
        for (int32 b = 0; b < p->data.numInputs; ++b) p->inBuses[b].silenceFlags = 0;
        p->data.numSamples = piece;
        p->context.projectTimeSamples = p->position;
        p->context.continousTimeSamples = p->position;
        p->outChanges.clear();

        tresult result = kResultOk;
        if (guardedProcess(p->processor.get(), &p->data, &result) != 0) {
            p->failed.store(true);
            status = 2;
            break;
        }
        if (result == kResultOk) {
            for (int e = 0; e < numChannels; ++e)
                memcpy(channels[e] + done, mainOut[p->map[e]], sizeof(float) * piece);
        } else {
            status = 3;    // left dry for this piece
        }
        // Output parameters (meters, gain reduction…) for the controller, which the editor's
        // timer hands on from the UI thread.
        for (int32 i = 0; i < p->outChanges.used; ++i) {
            const ParamQueue& q = p->outChanges.queues[i];
            if (q.count > 0) p->outputs.push(q.id, q.values[q.count - 1]);
        }
        p->inChanges.clear();    // edits belong to the first piece only
        p->position += piece;
        done += piece;
    }
    _mm_setcsr(mxcsr);
    return status;
}

extern "C" void nag_vst3_set_bypass(NAGVST3Plugin* p, int bypassed) {
    if (!p || !p->hasBypassParam || p->failed.load() || !p->controller) return;
    ParamValue value = bypassed ? 1.0 : 0.0;
    p->controller->setParamNormalized(p->bypassParam, value);
    std::lock_guard<std::mutex> guard(p->editProducer);
    p->edits.push(p->bypassParam, value);
}

namespace {

const char stateMagic[4] = {'N', 'A', 'G', '3'};

void put64(std::vector<uint8_t>& out, uint64_t v) {
    for (int i = 0; i < 8; ++i) out.push_back((uint8_t)(v >> (8 * i)));
}
uint64_t get64(const uint8_t* p) {
    uint64_t v = 0;
    for (int i = 0; i < 8; ++i) v |= (uint64_t)p[i] << (8 * i);
    return v;
}

} // namespace

/// The blob: "NAG3", a version (1, little-endian 32-bit), then the component's state and the
/// controller's state, each as a little-endian 64-bit length and its bytes.
extern "C" int nag_vst3_get_state(NAGVST3Plugin* p, uint8_t** data, int64_t* size) {
    if (!p || !data || !size || p->failed.load() || !p->component) return -1;
    MemoryStream componentState, controllerState;
    if (p->component->getState(&componentState) != kResultOk) componentState.setSize(0);
    if (p->controller && p->controller->getState(&controllerState) != kResultOk) controllerState.setSize(0);
    std::vector<uint8_t> out(stateMagic, stateMagic + 4);
    out.insert(out.end(), {1, 0, 0, 0});
    put64(out, (uint64_t)componentState.getSize());
    out.insert(out.end(), componentState.getData(), componentState.getData() + componentState.getSize());
    put64(out, (uint64_t)controllerState.getSize());
    out.insert(out.end(), controllerState.getData(), controllerState.getData() + controllerState.getSize());
    *data = (uint8_t*)malloc(out.size());
    if (!*data) return -1;
    memcpy(*data, out.data(), out.size());
    *size = (int64_t)out.size();
    return 0;
}

extern "C" int nag_vst3_set_state(NAGVST3Plugin* p, const uint8_t* data, int64_t size) {
    if (!p || !data || size < 24 || p->failed.load() || !p->component) return -1;
    if (memcmp(data, stateMagic, 4) != 0 || data[4] != 1) return -2;
    uint64_t componentSize = get64(data + 8);
    if (componentSize > (uint64_t)size - 24) return -2;
    const uint8_t* componentBytes = data + 16;
    uint64_t controllerSize = get64(componentBytes + componentSize);
    if (16 + componentSize + 8 + controllerSize > (uint64_t)size) return -2;
    const uint8_t* controllerBytes = componentBytes + componentSize + 8;

    // MemoryStream reads memory it is given without taking it over.
    MemoryStream componentState((void*)componentBytes, (TSize)componentSize);
    if (p->component->setState(&componentState) != kResultOk) return -3;
    if (p->controller) {
        componentState.seek(0, IBStream::kIBSeekSet, nullptr);
        p->controller->setComponentState(&componentState);
        if (controllerSize > 0) {
            MemoryStream controllerState((void*)controllerBytes, (TSize)controllerSize);
            p->controller->setState(&controllerState);
        }
    }
    return 0;
}
