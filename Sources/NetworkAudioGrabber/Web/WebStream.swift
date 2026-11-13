import Foundation
import AudioToolbox

/// What a probe learnt about an internet stream, enough to list it and build its receiver.
struct WebStreamInfo: Equatable {
    var url: String            // the stream itself, after any playlist
    var name: String
    var codec: String
    var sampleRate: Int
    var channels: Int
    var bitrate: Int?          // kbit/s, as the server states it

    var asDictionary: [String: Any] {
        var d: [String: Any] = ["url": url, "name": name, "codec": codec,
                                "rate": sampleRate, "channels": channels]
        if let bitrate { d["bitrate"] = bitrate }
        return d
    }

    init(url: String, name: String, codec: String, sampleRate: Int, channels: Int, bitrate: Int?) {
        self.url = url; self.name = name; self.codec = codec
        self.sampleRate = sampleRate; self.channels = channels; self.bitrate = bitrate
    }

    init?(_ d: [String: Any]) {
        guard let url = d["url"] as? String, let name = d["name"] as? String,
              let rate = d["rate"] as? Int, let channels = d["channels"] as? Int,
              (8000...384_000).contains(rate), (1...8).contains(channels) else { return nil }
        self.init(url: url, name: name, codec: d["codec"] as? String ?? "compressed",
                  sampleRate: rate, channels: channels, bitrate: d["bitrate"] as? Int)
    }

    var description: StreamDescription {
        let host = WebParsing.target(url)?.host ?? url
        return StreamDescription(name: name, originAddress: host, groupAddress: url, port: 0,
                                 payloadType: 0, encoding: .F32, sampleRate: sampleRate,
                                 channels: channels, ptimeMs: 50, ptpRef: nil, source: .web,
                                 rawSDP: "", codec: codec + (bitrate.map { " \($0) kbit/s" } ?? ""))
    }
}

/// Connects once, follows playlists, and reads just far enough to learn the stream's name and
/// format. Everything it reports arrives on the main queue.
final class WebStreamProbe {
    private var stream: HTTPStream?
    private var decoder: WebAudioDecoder?
    private var head: WebParsing.Head?
    private var finalURL = ""
    private var playlistBytes: [UInt8] = []
    private var isPlaylist = false
    private var hops = 0
    private var done = false
    private var completion: ((Result<WebStreamInfo, WebStreamProbe.Failure>) -> Void)?

    struct Failure: Error { let message: String }

    /// Probes `text` (an http(s) URL). Times out after ten seconds.
    func run(_ text: String, completion: @escaping (Result<WebStreamInfo, Failure>) -> Void) {
        self.completion = completion
        guard let target = WebParsing.target(text) else {
            finish(.failure(Failure(message: "Type a web address starting http:// or https://.")))
            return
        }
        open(target)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.finish(.failure(Failure(message: "The stream did not answer within ten seconds.")))
        }
    }

    private func open(_ target: WebParsing.Target) {
        head = nil; decoder = nil; playlistBytes.removeAll(); isPlaylist = false
        let s = HTTPStream(target: target) { [weak self] event in self?.handle(event, target: target) }
        stream = s
        s.start()
    }

    private func handle(_ event: HTTPStream.Event, target: WebParsing.Target) {
        switch event {
        case .head(let h, let url):
            head = h
            finalURL = url
            let type = h.contentType
            if WebParsing.isPlaylist(contentType: type, path: WebParsing.target(url)?.path ?? "") {
                isPlaylist = true
            } else if type.contains("ogg") || type.contains("opus") || type.contains("vorbis") {
                fail("Ogg streams (Vorbis, Opus) are not supported yet — look for an MP3 or AAC link from the same station.")
            } else if type.contains("text/html") {
                fail("That address is a web page, not a stream. Look for the station's direct stream link (often ending .mp3, .aac or .m3u).")
            } else {
                let d = WebAudioDecoder(typeHint: WebAudioDecoder.typeHint(contentType: type), rate: nil, channels: nil)
                d.onFormat = { [weak self] asbd in self?.formatKnown(asbd) }
                decoder = d
            }
        case .audio(let bytes):
            if isPlaylist {
                playlistBytes += bytes
                if playlistBytes.count > 65_536 { fail("That playlist is too long to read.") }
                return
            }
            if bytes.starts(with: Array("OggS".utf8)) {
                fail("Ogg streams (Vorbis, Opus) are not supported yet — look for an MP3 or AAC link from the same station.")
                return
            }
            decoder?.feed(bytes)
            if let failure = decoder?.failure { fail(failure) }
        case .title:
            break
        case .ended(let error):
            if isPlaylist { followPlaylist(); return }
            if !done { fail(error ?? "The stream ended before its format could be read.") }
        }
    }

    private func followPlaylist() {
        switch WebParsing.playlist(String(decoding: playlistBytes, as: UTF8.self)) {
        case .hls:
            fail("That is an HLS playlist (.m3u8), which this app does not play yet.")
        case .empty:
            fail("That playlist has no stream address in it.")
        case .stream(let next):
            hops += 1
            guard hops <= 3, let target = WebParsing.target(next) else { fail("The playlist's stream address cannot be opened."); return }
            open(target)
        }
    }

    private func formatKnown(_ asbd: AudioStreamBasicDescription) {
        guard let head else { return }
        let fallback = WebParsing.target(finalURL)?.host ?? "Internet stream"
        let name = head.headers["icy-name"].map { String($0.prefix(80)) }.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        let bitrate = head.headers["icy-br"].flatMap { Int($0.split(separator: ",").first ?? "") }
        let info = WebStreamInfo(url: finalURL, name: name, codec: asbd.codecName,
                                 sampleRate: Int(asbd.mSampleRate), channels: Int(asbd.mChannelsPerFrame),
                                 bitrate: bitrate)
        finish(.success(info))
    }

    private func fail(_ message: String) { finish(.failure(Failure(message: message))) }

    private func finish(_ result: Result<WebStreamInfo, Failure>) {
        DispatchQueue.main.async { [self] in
            guard !done else { return }
            done = true
            stream?.stop()
            stream = nil
            completion?(result)
            completion = nil
        }
    }
}

/// Plays one internet stream: an `HTTPStream` for the bytes, a `WebAudioDecoder` for the
/// audio, and `StreamReceiver` for everything after — the ring, drift control, fold-down, meters.
///
/// Reads while the ring holds less than 1.2 times the playout target, so a server's
/// burst at connect fills the buffer and then TCP holds the rest back. A dropped connection is
/// tried again, with a growing wait, until the stream is left.
final class WebStreamReceiver: StreamReceiver {
    private let url: String
    private var connection: HTTPStream?
    private var decoder: WebAudioDecoder?
    private var running = false
    private var retries = 0
    private let lock = NSLock()
    private var _title: String?
    private var _status: String?

    /// The current track, from the stream's ICY metadata.
    var nowPlaying: String? { lock.lock(); defer { lock.unlock() }; return _title }
    /// Why it is not playing, when it is not: a connection that failed, a retry pending.
    var problem: String? { lock.lock(); defer { lock.unlock() }; return _status }
    /// Log lines, on the main queue.
    var onLog: (String) -> Void = { _ in }

    override init(stream: StreamDescription, latencyMs: Double) {
        url = stream.groupAddress
        super.init(stream: stream, latencyMs: latencyMs)
        driftDeadband = 0.4
        receivingWindow = 5
        countsArrivalGaps = false
    }

    deinit { connection?.stop() }

    override func start(interfaceAddress: String) -> String? {
        guard let target = WebParsing.target(url) else { return "The stream's address is not a web address." }
        running = true
        connect(target)
        return nil
    }

    override func stop() {
        running = false
        connection?.stop()
        connection = nil
    }

    private func connect(_ target: WebParsing.Target) {
        guard running else { return }
        let s = HTTPStream(target: target) { [weak self] event in self?.handle(event) }
        s.wantsMore = { [weak self] in
            guard let self else { return false }
            return self.ring.availableFrames < Double(self.targetFrames) * 1.2
        }
        connection = s
        s.start()
    }

    private func set(title: String? = nil, status: String?) {
        lock.lock()
        if let title { _title = title }
        _status = status
        lock.unlock()
    }

    /// On the connection's queue.
    private func handle(_ event: HTTPStream.Event) {
        switch event {
        case .head(let h, _):
            let d = WebAudioDecoder(typeHint: WebAudioDecoder.typeHint(contentType: h.contentType),
                                    rate: Double(stream.sampleRate), channels: stream.channels)
            d.onFrames = { [weak self] samples, frames in self?.take(samples, frames: frames) }
            decoder = d
            set(status: nil)
        case .audio(let bytes):
            decoder?.feed(bytes)
            if retries > 0, decoder?.sourceFormat != nil { retries = 0 }
        case .title(let title):
            let old = nowPlaying
            set(title: title, status: problem)
            if title != old { DispatchQueue.main.async { [weak self] in self?.onLog("“\(self?.stream.name ?? "")”: now playing \(title).") } }
        case .ended(let error):
            decoder = nil
            guard running else { return }
            retries += 1
            let wait = [2.0, 4, 8, 15, 30][min(retries - 1, 4)]
            let why = error ?? "The server closed the stream."
            set(status: "\(why) Trying again in \(Int(wait)) s.")
            DispatchQueue.main.async { [weak self] in
                self?.onLog("“\(self?.stream.name ?? "")”: \(why) Trying again in \(Int(wait)) s.")
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self, self.running, let target = WebParsing.target(self.url) else { return }
                self.connect(target)
            }
        }
    }

    /// Decoded frames into the receiver, in pieces no bigger than its scratch holds.
    private func take(_ samples: UnsafePointer<Float>, frames: Int) {
        let channels = stream.channels
        var done = 0
        while done < frames {
            let n = min(maxPacketFrames, frames - done)
            scratch.update(from: samples + done * channels, count: n * channels)
            deliver(frames: n)
            done += n
        }
    }
}
