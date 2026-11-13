import Foundation
import Network

/// One HTTP or ICY stream connection: our own small client over Network.framework, because
/// SHOUTcast servers answer "ICY 200 OK", which URLSession refuses, and because this reads **only
/// when asked** — the receiver pulls while its buffer wants more and stops when it is full, so TCP
/// itself paces the server rather than the app draining a burst by playing it fast.
///
/// HTTP/1.0 on purpose: a server must not answer a 1.0 request with chunked encoding, so the body
/// is the audio as sent. Redirects are followed, up to five. Everything runs on one private
/// queue; the callbacks come on it too.
final class HTTPStream {
    enum Event {
        /// The response head, once, before any body.
        case head(WebParsing.Head, finalURL: String)
        /// Body bytes, with ICY metadata already taken out.
        case audio([UInt8])
        /// A title from the ICY metadata.
        case title(String)
        /// The connection ended; nil for a clean close by the server.
        case ended(String?)
    }

    let queue = DispatchQueue(label: "HTTPStream", qos: .userInitiated)
    private var connection: NWConnection?
    private var target: WebParsing.Target
    private var redirects = 0
    private var buffer: [UInt8] = []
    private var head: WebParsing.Head?
    private var stopped = false
    private let onEvent: (Event) -> Void
    /// Asked before each read: false pauses reading until it says true again.
    var wantsMore: () -> Bool = { true }

    // ICY demultiplexing: audio bytes up to the next metadata block, then the block.
    private var metaInterval: Int?
    private var untilMeta = 0
    private var metaRemaining = -1          // −1: not inside a block
    private var metaBlock: [UInt8] = []

    init(target: WebParsing.Target, onEvent: @escaping (Event) -> Void) {
        self.target = target
        self.onEvent = onEvent
    }

    func start() { queue.async { self.connect() } }

    func stop() {
        queue.async {
            self.stopped = true
            self.connection?.cancel()
            self.connection = nil
        }
    }

    private func connect() {
        guard !stopped else { return }
        buffer.removeAll(); head = nil; metaInterval = nil; metaRemaining = -1; metaBlock.removeAll()
        let params: NWParameters = target.secure ? .tls : .tcp
        let c = NWConnection(host: NWEndpoint.Host(target.host),
                             port: NWEndpoint.Port(rawValue: target.port) ?? 80, using: params)
        connection = c
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.sendRequest()
            case .failed(let error), .waiting(let error): self.finish(self.plain(error))
            default: break
            }
        }
        c.start(queue: queue)
    }

    /// A connection error, said as what it means.
    private func plain(_ error: NWError) -> String {
        let where_ = target.port == (target.secure ? 443 : 80) ? target.host : "\(target.host):\(target.port)"
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return "Nothing is answering at \(where_)."
            case .ETIMEDOUT: return "\(where_) did not answer in time."
            case .ENETUNREACH, .EHOSTUNREACH: return "\(where_) cannot be reached from this network."
            case .ENETDOWN: return "This Mac is not connected to a network."
            default: return "Could not connect to \(where_) (\(code.rawValue))."
            }
        case .dns: return "Could not find \(target.host) — check the address."
        case .tls: return "The secure connection to \(target.host) failed."
        default: return "Could not connect to \(where_)."
        }
    }

    private func sendRequest() {
        let request = "GET \(target.path) HTTP/1.0\r\n"
            + "Host: \(target.host)\r\n"
            + "User-Agent: NetworkAudioGrabber\r\n"
            + "Accept: */*\r\n"
            + "Icy-MetaData: 1\r\n"
            + "Connection: close\r\n\r\n"
        connection?.send(content: Data(request.utf8), completion: .contentProcessed { [weak self] error in
            if let error { self?.finish("Could not send the request: \(error.localizedDescription)") }
            else { self?.read() }
        })
    }

    private func read() {
        guard !stopped, let c = connection else { return }
        // Past the head, only read what the listener wants: TCP flow control does the rest.
        if head != nil, !wantsMore() {
            queue.asyncAfter(deadline: .now() + .milliseconds(40)) { [weak self] in self?.read() }
            return
        }
        c.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.stopped else { return }
            if let data, !data.isEmpty { self.take([UInt8](data)) }
            if let error { self.finish("The connection dropped: \(error.localizedDescription)"); return }
            if complete { self.finish(nil); return }
            if !self.stopped, self.connection === c { self.read() }
        }
    }

    private func take(_ bytes: [UInt8]) {
        guard head == nil else { demux(bytes); return }
        buffer += bytes
        guard let parsed = WebParsing.head(buffer) else { return }
        switch parsed {
        case .bad(let message): finish(message)
        case .head(let h):
            let body = Array(buffer[h.length...])
            buffer.removeAll()
            if (300...399).contains(h.status), let location = h.location {
                follow(location)
                return
            }
            guard h.status == 200 else {
                finish(h.status == 404 ? "The server has no stream at that address (404)."
                       : "The server answered \(h.status).")
                return
            }
            head = h
            metaInterval = h.metaInterval
            untilMeta = h.metaInterval ?? 0
            onEvent(.head(h, finalURL: target.text))
            if !body.isEmpty { demux(body) }
        }
    }

    private func follow(_ location: String) {
        redirects += 1
        guard redirects <= 5 else { finish("The server redirected too many times."); return }
        let absolute = URL(string: location, relativeTo: URL(string: target.text))?.absoluteString ?? location
        guard let next = WebParsing.target(absolute) else { finish("The server redirected to an address this cannot open."); return }
        connection?.cancel()
        target = next
        connect()
    }

    /// Splits the body into audio and ICY metadata, if the server interleaves any.
    private func demux(_ bytes: [UInt8]) {
        guard let interval = metaInterval else { onEvent(.audio(bytes)); return }
        var audio: [UInt8] = []
        audio.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if metaRemaining >= 0 {
                // Inside a metadata block.
                let take = min(metaRemaining, bytes.count - i)
                metaBlock += bytes[i..<(i + take)]
                metaRemaining -= take
                i += take
                if metaRemaining == 0 {
                    if let title = WebParsing.streamTitle(metaBlock) { onEvent(.title(title)) }
                    metaBlock.removeAll()
                    metaRemaining = -1
                    untilMeta = interval
                }
            } else if untilMeta == 0 {
                // The length byte: the block is sixteen times it.
                metaRemaining = Int(bytes[i]) * 16
                i += 1
                if metaRemaining == 0 { metaRemaining = -1; untilMeta = interval }
            } else {
                let take = min(untilMeta, bytes.count - i)
                audio += bytes[i..<(i + take)]
                untilMeta -= take
                i += take
            }
        }
        if !audio.isEmpty { onEvent(.audio(audio)) }
    }

    private func finish(_ error: String?) {
        guard !stopped else { return }
        stopped = true
        connection?.cancel()
        connection = nil
        onEvent(.ended(error))
    }
}
