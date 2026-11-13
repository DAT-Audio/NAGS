import Foundation
import Network

/// Discovers RAVENNA sessions the way ANEMAN and Merging devices publish them: a Bonjour
/// advertisement of `_ravenna_session._sub._rtsp._tcp`, followed by an RTSP DESCRIBE that
/// returns the session's SDP.
///
/// Merging/Ravenna gear can also emit SAP, so this runs alongside `SAPListener` and the two
/// are de-duplicated by multicast group + port in `AppState`.
///
/// Bonjour only reports *changes*: a session that stays put is never reported again,
/// so each one found is asked for its description again every `refreshEvery` seconds. That keeps
/// a quiet session listed (the engine drops anything unannounced after two minutes), and picks up
/// a change to its SDP. A session that leaves Bonjour is reported with its last SDP (`onGone`).
final class RavennaBrowser: LeavingStreamBrowser {
    var onSDP: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onGone: ((String) -> Void)?

    private var browsers: [NWBrowser] = []
    private let queue = DispatchQueue(label: "ravenna.browser")
    private var inFlight = Set<String>()
    /// The sessions in Bonjour's latest results, by key, and the SDP each last gave. Queue only.
    private var services: [String: (name: String, type: String, domain: String)] = [:]
    private var described: [String: String] = [:]
    private var refresh: DispatchSourceTimer?
    private static let refreshEvery: TimeInterval = 60

    // NWBrowser rejects the `_sub` subtype syntax (NWError -65540), but RAVENNA sessions are
    // registered under plain `_rtsp._tcp` with the subtype attached, so browsing the base
    // type finds them all. Non-RAVENNA RTSP servers simply fail the DESCRIBE and are ignored.
    private static let serviceTypes = ["_rtsp._tcp"]

    func start() {
        stop()
        // Ordered ahead of the browsers on the same serial queue that delivers their callbacks.
        queue.async { self.inFlight.removeAll(); self.services.removeAll(); self.described.removeAll() }
        for type in Self.serviceTypes {
            let params = NWParameters.tcp
            params.includePeerToPeer = false
            let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: params)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                guard let self else { return }
                var now: [String: (name: String, type: String, domain: String)] = [:]
                for result in results {
                    guard case let .service(name, type, domain, _) = result.endpoint else { continue }
                    now["\(name)|\(type)|\(domain)"] = (name, type, domain)
                    self.describe(name: name, type: type, domain: domain)
                }
                // Results are per browser; with one service type, these are all of them.
                for key in self.services.keys where now[key] == nil {
                    if let sdp = self.described.removeValue(forKey: key) { self.onGone?(sdp) }
                }
                self.services = now
            }
            browser.stateUpdateHandler = { [weak self] state in
                if case let .failed(error) = state {
                    self?.onError?("Bonjour browse (\(type)) failed: \(error.localizedDescription)")
                }
            }
            browser.start(queue: queue)
            browsers.append(browser)
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.refreshEvery, repeating: Self.refreshEvery, leeway: .seconds(5))
        // Sessions that answered are asked every minute. Other RTSP servers on the network (a
        // camera, say) answer nothing useful, so they are only retried every fifth time.
        var round = 0
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            round += 1
            for (key, s) in self.services where self.described[key] != nil || round % 5 == 0 {
                self.describe(name: s.name, type: s.type, domain: s.domain)
            }
        }
        timer.resume()
        refresh = timer
    }

    func stop() {
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        refresh?.cancel()
        refresh = nil
        queue.async { self.inFlight.removeAll(); self.services.removeAll(); self.described.removeAll() }
    }

    /// Opens the RTSP port and asks for the session description.
    private func describe(name: String, type: String, domain: String) {
        let key = "\(name)|\(type)|\(domain)"
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)

        let endpoint = NWEndpoint.service(name: name, type: type, domain: domain, interface: nil)
        let conn = NWConnection(to: endpoint, using: .tcp)
        var finished = false

        let finish: () -> Void = { [weak self] in
            guard !finished else { return }
            finished = true
            conn.cancel()
            self?.queue.asyncAfter(deadline: .now() + 30) { self?.inFlight.remove(key) }
        }

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let host = Self.remoteHost(of: conn) ?? name
                let path = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
                let request = """
                DESCRIBE rtsp://\(host)/by-name/\(path) RTSP/1.0\r
                CSeq: 1\r
                Accept: application/sdp\r
                User-Agent: NetworkAudioGrabber\r
                \r

                """
                conn.send(content: request.data(using: .utf8), completion: .idempotent)
                Self.receive(conn) { body in
                    if let body, let self {
                        self.described[key] = body
                        self.onSDP?(body)
                    }
                    finish()
                }
            case .failed, .cancelled:
                finish()
            default:
                break
            }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { finish() }
    }

    private static func remoteHost(of conn: NWConnection) -> String? {
        guard case let .hostPort(host, _)? = conn.currentPath?.remoteEndpoint else { return nil }
        switch host {
        case .ipv4(let a): return "\(a)".split(separator: "%").first.map(String.init)
        case .ipv6(let a): return "[\(a)]"
        case .name(let n, _): return n
        @unknown default: return nil
        }
    }

    /// Accumulates the RTSP reply until the SDP body is complete, then hands back the body.
    private static func receive(_ conn: NWConnection,
                                completion: @escaping (String?) -> Void) {
        var acc = Data()
        func step() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data { acc.append(data) }
                if let text = String(data: acc, encoding: .utf8),
                   let range = text.range(of: "\r\n\r\n") ?? text.range(of: "\n\n") {
                    let head = String(text[text.startIndex..<range.lowerBound])
                    let body = String(text[range.upperBound...])
                    let declared = contentLength(in: head)
                    if declared == nil || body.utf8.count >= declared! || isComplete {
                        completion(head.contains(" 200 ") ? body : nil)
                        return
                    }
                }
                if isComplete || error != nil { completion(nil); return }
                step()
            }
        }
        step()
    }

    private static func contentLength(in head: String) -> Int? {
        for line in head.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }
}
