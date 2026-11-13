// Finding and describing VST3 modules, and running the scanner child (NAGVST3.h).

#include "NAGVST3Internal.h"

#include "public.sdk/source/vst/hosting/module.h"
#include "public.sdk/source/vst/moduleinfo/moduleinfoparser.h"

#include <shlobj.h>

#include <chrono>
#include <filesystem>
#include <fstream>
#include <sstream>

namespace fs = std::filesystem;
using namespace nagvst3;

namespace {

/// Unix seconds of a file's last write. `file_time_type` on MSVC counts from 1601.
int64_t unixTime(const fs::path& p) {
    std::error_code ec;
    auto t = fs::last_write_time(p, ec);
    if (ec) return 0;
    auto since1601 = std::chrono::duration_cast<std::chrono::seconds>(t.time_since_epoch()).count();
    return since1601 - 11644473600LL;
}

/// What identifies a module's version on disk: its binary's write time, which an installer
/// always changes, rather than the bundle folder's, which it may not.
int64_t moduleTime(const fs::path& module) {
    std::error_code ec;
    if (fs::is_directory(module, ec)) {
        auto binary = module / "Contents" / "x86_64-win" / module.filename();
        if (fs::exists(binary, ec)) return unixTime(binary);
    }
    return unixTime(module);
}

bool hasVST3Extension(const fs::path& p) {
    auto ext = p.extension().wstring();
    return _wcsicmp(ext.c_str(), L".vst3") == 0;
}

void findIn(const fs::path& folder, std::string& out) {
    std::error_code ec;
    fs::directory_iterator it(folder, fs::directory_options::skip_permission_denied, ec), end;
    if (ec) return;
    for (; it != end; it.increment(ec)) {
        if (ec) break;
        const auto& p = it->path();
        std::error_code e2;
        bool dir = it->is_directory(e2);
        if (hasVST3Extension(p)) {
            // A bundle is a module, not a folder to look inside: its Contents hold the binary.
            out += utf8(p.wstring()) + "\t" + std::to_string(moduleTime(p)) + "\n";
        } else if (dir) {
            // Vendor folders: IEM, Kilohearts, Soundtoys…
            findIn(p, out);
        }
    }
}

void appendClass(std::string& json, bool& first, const std::string& cid, const std::string& name,
                 const std::string& vendor, const std::string& category,
                 const std::vector<std::string>& subCategories, const std::string& version) {
    if (!first) json += ",";
    first = false;
    json += "{\"cid\":\"" + jsonEscape(cid) + "\",\"name\":\"" + jsonEscape(name) + "\",\"vendor\":\"" +
            jsonEscape(vendor) + "\",\"category\":\"" + jsonEscape(category) + "\",\"subCategories\":[";
    for (size_t i = 0; i < subCategories.size(); ++i) {
        if (i) json += ",";
        json += "\"" + jsonEscape(subCategories[i]) + "\"";
    }
    json += "],\"version\":\"" + jsonEscape(version) + "\"}";
}

} // namespace

extern "C" char* nag_vst3_default_folder(void) {
    PWSTR folder = nullptr;
    std::string result;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_ProgramFilesCommon, 0, nullptr, &folder)) && folder)
        result = utf8((fs::path(folder) / "VST3").wstring());
    CoTaskMemFree(folder);
    return mallocString(result);
}

extern "C" char* nag_vst3_find_modules(const char* folderUtf8) {
    std::string out;
    std::string folder = folderUtf8 ? std::string(folderUtf8) : std::string();
    if (folder.empty()) {
        char* d = nag_vst3_default_folder();
        folder = d;
        free(d);
    }
    findIn(fs::path(wide(folder)), out);
    return mallocString(out);
}

extern "C" char* nag_vst3_describe_module(const char* pathUtf8, int allowLoad) {
    std::string path = pathUtf8 ? pathUtf8 : "";
    std::string classes, vendor, error, source;
    bool first = true;

    // moduleinfo.json first: the plug-in's own description, read without running any of its code.
    if (auto infoPath = VST3::Hosting::Module::getModuleInfoPath(path)) {
        std::ifstream file(fs::u8path(*infoPath), std::ios::binary);
        std::stringstream text;
        text << file.rdbuf();
        std::string data = text.str();
        if (auto info = Steinberg::ModuleInfoLib::parseJson(data, nullptr)) {
            source = "moduleinfo";
            vendor = info->factoryInfo.vendor;
            for (const auto& c : info->classes)
                appendClass(classes, first, c.cid, c.name, c.vendor.empty() ? vendor : c.vendor,
                            c.category, c.subCategories, c.version);
        }
    }

    if (source.empty()) {
        if (!allowLoad) {
            error = "not described without loading";
        } else {
            std::string why;
            auto module = VST3::Hosting::Module::create(path, why);
            if (!module) {
                error = why.empty() ? "could not be loaded" : why;
            } else {
                source = "module";
                const auto& factory = module->getFactory();
                vendor = factory.info().vendor();
                for (const auto& c : factory.classInfos())
                    appendClass(classes, first, c.ID().toString(), c.name(),
                                c.vendor().empty() ? vendor : c.vendor(), c.category(),
                                c.subCategories(), c.version());
            }
        }
    }

    std::string json = "{\"path\":\"" + jsonEscape(path) + "\",\"source\":\"" + jsonEscape(source) +
                       "\",\"vendor\":\"" + jsonEscape(vendor) + "\",\"error\":\"" + jsonEscape(error) +
                       "\",\"classes\":[" + classes + "]}";
    return mallocString(json);
}

extern "C" void nag_vst3_quiet_crashes(void) {
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
}

extern "C" char* nag_vst3_run_child(const char* exeUtf8, const char* argsUtf8, const char* stdinUtf8,
                                    int idleTimeoutMs, int* exitCode, int* timedOut) {
    if (exitCode) *exitCode = -1;
    if (timedOut) *timedOut = 0;
    SECURITY_ATTRIBUTES sa {sizeof(sa), nullptr, TRUE};
    HANDLE inRead = nullptr, inWrite = nullptr, outRead = nullptr, outWrite = nullptr;
    // Big pipes, so the whole list of paths goes in before the child has read any of it.
    if (!CreatePipe(&inRead, &inWrite, &sa, 1 << 20)) return nullptr;
    if (!CreatePipe(&outRead, &outWrite, &sa, 1 << 16)) {
        CloseHandle(inRead); CloseHandle(inWrite);
        return nullptr;
    }
    SetHandleInformation(inWrite, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(outRead, HANDLE_FLAG_INHERIT, 0);

    STARTUPINFOW si {};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = inRead;
    si.hStdOutput = outWrite;
    si.hStdError = outWrite;
    PROCESS_INFORMATION pi {};

    std::wstring command = L"\"" + wide(exeUtf8 ? exeUtf8 : "") + L"\"";
    if (argsUtf8 && *argsUtf8) command += L" " + wide(argsUtf8);
    std::vector<wchar_t> commandLine(command.begin(), command.end());
    commandLine.push_back(0);

    // CREATE_NO_WINDOW: a console child of a windowed app would otherwise flash a console up.
    BOOL started = CreateProcessW(nullptr, commandLine.data(), nullptr, nullptr, TRUE,
                                  CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi);
    CloseHandle(inRead);
    CloseHandle(outWrite);
    if (!started) {
        CloseHandle(inWrite); CloseHandle(outRead);
        return nullptr;
    }

    if (stdinUtf8) {
        DWORD length = (DWORD)strlen(stdinUtf8), written = 0;
        WriteFile(inWrite, stdinUtf8, length, &written, nullptr);
    }
    CloseHandle(inWrite);

    std::string output;
    char buffer[4096];
    ULONGLONG lastOutput = GetTickCount64();
    bool killed = false;
    for (;;) {
        DWORD available = 0;
        if (!PeekNamedPipe(outRead, nullptr, 0, nullptr, &available, nullptr)) break;   // closed
        if (available > 0) {
            DWORD got = 0;
            if (!ReadFile(outRead, buffer, (DWORD)std::min<size_t>(sizeof(buffer), available), &got, nullptr) || got == 0)
                break;
            output.append(buffer, got);
            lastOutput = GetTickCount64();
            continue;
        }
        if (WaitForSingleObject(pi.hProcess, 20) == WAIT_OBJECT_0) {
            // Exited: whatever is still in the pipe is read on the next turns, until it is empty.
            DWORD rest = 0;
            if (!PeekNamedPipe(outRead, nullptr, 0, nullptr, &rest, nullptr) || rest == 0) break;
            continue;
        }
        if (idleTimeoutMs > 0 && GetTickCount64() - lastOutput > (ULONGLONG)idleTimeoutMs) {
            // A plug-in waiting on a dialog nobody can see, or stuck: give up on it.
            TerminateProcess(pi.hProcess, 1);
            WaitForSingleObject(pi.hProcess, 2000);
            killed = true;
            break;
        }
    }
    DWORD code = (DWORD)-1;
    if (!killed) {
        WaitForSingleObject(pi.hProcess, 5000);
        GetExitCodeProcess(pi.hProcess, &code);
    }
    if (exitCode) *exitCode = killed ? -1 : (int)code;
    if (timedOut) *timedOut = killed ? 1 : 0;
    CloseHandle(outRead);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    return mallocString(output);
}
