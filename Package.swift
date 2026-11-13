// swift-tools-version: 5.9
import PackageDescription

// Two apps and what they share. The Grabber receives network audio; the Sender transmits this
// Mac's audio as VBAN. `NetworkAudioShared` is the wire format and the look both apps draw with,
// so the pair cannot drift apart.
// The AudioUnitSDK is written to C++23 (std::expected).
let cxx23: [CXXSetting] = [.unsafeFlags(["-std=c++23"])]
let release: [SwiftSetting] = [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]

#if os(Windows)
// On Windows: the shared engine, its check, and the Windows
// apps. The Mac's apps, Audio Units and AudioUnitSDK are not built here. Build outside the synced folder:
//   swift build --scratch-path <a build folder outside the source tree>
let package = Package(
    name: "NetworkAudioGrabber",
    products: [
        .executable(name: "NetworkAudioEngineCheck", targets: ["NetworkAudioEngineCheck"]),
        // M2: the Sender, without a window. `nag-send --help` says what it takes.
        .executable(name: "nag-send", targets: ["SenderConsole"]),
        // M4: the same Sender with a window, drawn in plain Win32, with no dependency and no licence to accept.
        .executable(name: "nag-sender", targets: ["SenderWindow"]),
        // The Windows Grabber beta: without a window, then with one.
        .executable(name: "nag-grab", targets: ["GrabberConsole"]),
        .executable(name: "nag-grabber", targets: ["GrabberWindow"]),
        // VST3 inserts: the crash-safe scanner child the catalog runs, and a check
        // that loads and processes real plug-ins without any audio device.
        .executable(name: "nag-vst3-scan", targets: ["VST3Scan"]),
        .executable(name: "nag-vst3-check", targets: ["VST3Check"]),
    ],
    // Encryption for the Remote link: Apple's swift-crypto,
    // Apache-2.0 — CryptoKit on the Mac, its own BoringSSL elsewhere. Credited in Settings → Credits.
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", "4.5.0"..<"6.0.0"),
    ],
    targets: [
        .target(name: "NetworkAudioAtomics", path: "Sources/NetworkAudioAtomics"),
        .target(name: "NetworkAudioEngine", dependencies: ["NetworkAudioAtomics", .product(name: "Crypto", package: "swift-crypto")],
                path: "Sources/NetworkAudioEngine",
                swiftSettings: release),      // as the Mac builds it
        .executableTarget(name: "NetworkAudioEngineCheck", dependencies: ["NetworkAudioEngine"],
                          path: "Sources/NetworkAudioEngineCheck"),
        // WASAPI loopback and render as plain C: Swift's WinSDK module does not carry
        // mmdeviceapi.h or audioclient.h, so the COM calls live here. `ole32` for COM itself,
        // `avrt` for MMCSS, which schedules the Grabber's render thread as audio.
        .target(name: "NAGWASAPI", path: "Sources/Windows/NAGWASAPI",
                publicHeadersPath: "include",
                linkerSettings: [.linkedLibrary("ole32"), .linkedLibrary("avrt"), .linkedLibrary("mmdevapi")]),
        // What both Senders are: this PC's audio, and the engine over it. Neither the console nor
        // the window has any of it of its own.
        .target(name: "SenderCore", dependencies: ["NetworkAudioEngine", "NAGWASAPI"],
                path: "Sources/Windows/SenderCore",
                swiftSettings: release),
        .executableTarget(name: "SenderConsole", dependencies: ["SenderCore"],
                          path: "Sources/Windows/SenderConsole",
                          swiftSettings: release),
        // Left as a console subsystem app on purpose: linking it /SUBSYSTEM:WINDOWS started a
        // process that never made its window, and the console it would otherwise open is
        // disowned at startup instead (`FreeConsole`, in main.swift), which also leaves a
        // terminal it was launched from alone.
        .executableTarget(name: "SenderWindow", dependencies: ["AppUI"],
                          path: "Sources/Windows/SenderWindow",
                          swiftSettings: release),
        // The look both windows share (moved out of SenderWindow unchanged): the
        // theme, GDI drawing, Windows' own menus and text fields.
        .target(name: "Win32UI", path: "Sources/Windows/Win32UI", swiftSettings: release),
        // What both Grabbers are: the engine's `GrabberEngine` over WASAPI render.
        .target(name: "GrabberCore", dependencies: ["NetworkAudioEngine", "NAGWASAPI", "WindowsInserts"],
                path: "Sources/Windows/GrabberCore",
                swiftSettings: release),
        .executableTarget(name: "GrabberConsole", dependencies: ["GrabberCore"],
                          path: "Sources/Windows/GrabberConsole",
                          swiftSettings: release),
        // Antialiased shapes through GDI+, which ships with Windows (the full window).
        .target(name: "NAGDraw", path: "Sources/Windows/NAGDraw",
                publicHeadersPath: "include",
                linkerSettings: [.linkedLibrary("gdiplus"), .linkedLibrary("shlwapi")]),
        // A console subsystem app that disowns its console, as `nag-sender` is.
        // Both windows: the drawing, the look, the controls, the Send and inserts views,
        // the Grabber's window and the Sender's, in one library; each app is a line that starts it.
        .target(name: "AppUI", dependencies: ["GrabberCore", "SenderCore", "Win32UI", "NAGDraw", "WindowsInserts"],
                path: "Sources/Windows/AppUI",
                swiftSettings: release),
        .executableTarget(name: "GrabberWindow", dependencies: ["AppUI"],
                          path: "Sources/Windows/GrabberWindow",
                          swiftSettings: release),
        // VST3 hosting for the monitor inserts: Steinberg's VST 3 SDK, MIT since 3.8,
        // vendored as the hosting subset only (NAGVST3/vst3sdk, LICENSE.txt and VERSION.txt
        // there), behind a plain C API, because Swift cannot import C++ classes reliably here.
        // Only the files listed are compiled. C++17 rather than 20: the SDK reads UTF-8 paths
        // with `u8path` only below C++20.
        .target(name: "NAGVST3", path: "Sources/Windows/NAGVST3",
                exclude: ["vst3sdk/LICENSE.txt", "vst3sdk/VERSION.txt",
                          "vst3sdk/pluginterfaces/LICENSE.txt", "vst3sdk/public.sdk/LICENSE.txt",
                          "vst3sdk/pluginterfaces/base/conststringtable.cpp",
                          "vst3sdk/pluginterfaces/base/ustring.cpp"],
                sources: ["src",
                          "vst3sdk/pluginterfaces/base/funknown.cpp",
                          "vst3sdk/pluginterfaces/base/coreiids.cpp",
                          "vst3sdk/public.sdk/source/vst/vstinitiids.cpp",
                          "vst3sdk/public.sdk/source/vst/hosting/module.cpp",
                          "vst3sdk/public.sdk/source/vst/hosting/module_win32.cpp",
                          "vst3sdk/public.sdk/source/vst/hosting/hostclasses.cpp",
                          "vst3sdk/public.sdk/source/vst/hosting/pluginterfacesupport.cpp",
                          "vst3sdk/public.sdk/source/vst/hosting/connectionproxy.cpp",
                          "vst3sdk/public.sdk/source/vst/utility/stringconvert.cpp",
                          "vst3sdk/public.sdk/source/vst/moduleinfo/moduleinfoparser.cpp",
                          "vst3sdk/public.sdk/source/common/commonstringconvert.cpp",
                          "vst3sdk/public.sdk/source/common/commoniids.cpp",
                          "vst3sdk/public.sdk/source/common/memorystream.cpp",
                          "vst3sdk/public.sdk/source/common/threadchecker_win32.cpp"],
                publicHeadersPath: "include",
                cxxSettings: [.headerSearchPath("vst3sdk"), .define("RELEASE", to: "1"),
                              .define("UNICODE"), .define("_UNICODE"), .define("NOMINMAX"),
                              .define("_CRT_SECURE_NO_WARNINGS"),
                              .define("_SILENCE_ALL_CXX17_DEPRECATION_WARNINGS"),
                              .unsafeFlags(["-std=c++17", "-Wno-pragma-pack", "-Wno-format"])],
                linkerSettings: [.linkedLibrary("ole32"), .linkedLibrary("shell32"),
                                 .linkedLibrary("user32"), .linkedLibrary("uuid")]),
        // The three insert slots over NAGVST3, as the Mac's `InsertChain` over Audio Units.
        .target(name: "WindowsInserts", dependencies: ["NAGVST3", "NetworkAudioEngine"],
                path: "Sources/Windows/Inserts/WindowsInserts",
                swiftSettings: release),
        .executableTarget(name: "VST3Scan", dependencies: ["WindowsInserts"],
                          path: "Sources/Windows/Inserts/Scan"),
        .executableTarget(name: "VST3Check", dependencies: ["WindowsInserts"],
                          path: "Sources/Windows/Inserts/Check"),
    ]
)
#else
let package = Package(
    name: "NetworkAudioGrabber",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "NetworkAudioGrabber", targets: ["NetworkAudioGrabberApp"]),
        .executable(name: "NetworkAudioSender", targets: ["NetworkAudioSenderApp"]),
        // The Grabber as an Audio Unit: the same core, wrapped by `build.sh` into a .component.
        .library(name: "NetworkAudioGrabberAU", type: .dynamic,
                 targets: ["NetworkAudioGrabberCore", "NetworkAudioGrabberAU"]),
    ],
    // Encryption for the Remote link: Apple's swift-crypto,
    // Apache-2.0 — CryptoKit on the Mac, its own BoringSSL elsewhere. Credited in Settings → Credits.
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", "4.5.0"..<"6.0.0"),
    ],
    targets: [
        // C11 atomics for the values the audio and network threads share with the UI (PF-12).
        .target(
            name: "NetworkAudioAtomics",
            path: "Sources/NetworkAudioAtomics"
        ),
        // The engine: what the apps do, with nothing of Apple's but Foundation, so
        // the Windows port is built from the same code. No SwiftUI, AppKit, Core Audio or
        // CryptoKit here — `Tools/check-engine.sh` says if one creeps in.
        .target(
            name: "NetworkAudioEngine",
            dependencies: ["NetworkAudioAtomics", .product(name: "Crypto", package: "swift-crypto")],
            path: "Sources/NetworkAudioEngine",
            swiftSettings: release
        ),
        .target(
            name: "NetworkAudioShared",
            dependencies: ["NetworkAudioEngine", "NetworkAudioAtomics"],
            path: "Sources/NetworkAudioShared",
            swiftSettings: release
        ),
        // Everything the Grabber is, as a library, so the app and the Audio Unit plugin are built
        // from the same sources: a change to one is a change to both.
        .target(
            name: "NetworkAudioGrabberCore",
            dependencies: ["NetworkAudioShared", "NetworkAudioSenderCore", "NetworkAudioAtomics"],
            path: "Sources/NetworkAudioGrabber",
            swiftSettings: release
        ),
        .executableTarget(
            name: "NetworkAudioGrabberApp",
            dependencies: ["NetworkAudioGrabberCore"],
            path: "Sources/NetworkAudioGrabberApp",
            swiftSettings: release
        ),
        // Apple's AudioUnitSDK, vendored unchanged (Apache-2.0, Sources/AudioUnitSDK/LICENSE.txt).
        .target(
            name: "AudioUnitSDK",
            path: "Sources/AudioUnitSDK",
            exclude: ["LICENSE.txt", "VERSION.txt"],
            sources: ["src"],
            publicHeadersPath: "include",
            cxxSettings: cxx23,
            linkerSettings: [.linkedFramework("AudioToolbox"), .linkedFramework("CoreAudio"),
                             .linkedFramework("CoreFoundation")]
        ),
        // The two components (instrument and effect) over the Grabber's core.
        .target(
            name: "NetworkAudioGrabberAU",
            dependencies: ["AudioUnitSDK"],
            path: "Sources/NetworkAudioGrabberAU",
            cxxSettings: cxx23,
            linkerSettings: [.linkedFramework("CoreAudioKit")]
        ),
        // Everything the Sender is, as a library, so the Grabber's Send area is the Sender's own code.
        .target(
            name: "NetworkAudioSenderCore",
            dependencies: ["NetworkAudioShared", "NetworkAudioAtomics"],
            path: "Sources/NetworkAudioSender",
            swiftSettings: release
        ),
        // The engine on its own, on any platform: `swift run NetworkAudioEngineCheck`.
        .executableTarget(
            name: "NetworkAudioEngineCheck",
            dependencies: ["NetworkAudioEngine"],
            path: "Sources/NetworkAudioEngineCheck"
        ),
        .executableTarget(
            name: "NetworkAudioSenderApp",
            dependencies: ["NetworkAudioSenderCore"],
            path: "Sources/NetworkAudioSenderApp",
            swiftSettings: release
        ),
    ]
)
#endif
