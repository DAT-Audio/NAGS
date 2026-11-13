// Shared by the NAGVST3 sources; not part of the C API.

#pragma once

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <string>

namespace nagvst3 {

inline std::wstring wide(const std::string& s) {
    if (s.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
    std::wstring w(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), w.data(), n);
    return w;
}

inline std::string utf8(const std::wstring& w) {
    if (w.empty()) return {};
    int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    std::string s(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), s.data(), n, nullptr, nullptr);
    return s;
}

inline char* mallocString(const std::string& s) {
    char* p = (char*)malloc(s.size() + 1);
    if (p) memcpy(p, s.c_str(), s.size() + 1);
    return p;
}

/// One line of JSON, so the scanner child's output can be read line by line.
inline std::string jsonEscape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 8);
    for (unsigned char c : s) {
        switch (c) {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if (c < 0x20) {
                char tmp[8];
                snprintf(tmp, sizeof(tmp), "\\u%04x", c);
                out += tmp;
            } else {
                out += (char)c;
            }
        }
    }
    return out;
}

inline void copyError(char* error, int capacity, const std::string& text) {
    if (!error || capacity <= 0) return;
    size_t n = std::min<size_t>(text.size(), (size_t)capacity - 1);
    memcpy(error, text.data(), n);
    error[n] = 0;
}

} // namespace nagvst3
