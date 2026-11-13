#!/usr/bin/env python3
"""A fake plain-RTP sender — RTP audio with no PTP clock, as PipeWire, PulseAudio, VLC and
GStreamer send it — for testing the Grabber's plain-RTP path without any of them.

Announces the session over SAP (unless --no-sap) with an SDP that names no PTP clock, and sends
an L16 or L24 tone (440 Hz upward, a step per channel). Written from RFC 3550, 3551, 3190 and
2974; no code from any of those projects is used.

    ./rtp_send.py --iface-ip 127.0.0.1                          # multicast, L16/48000/2, PT 127
    ./rtp_send.py --iface-ip 127.0.0.1 --pt 10 --no-rtpmap      # static PT 10: L16/44100/2
    ./rtp_send.py --iface-ip 127.0.0.1 --to 127.0.0.1           # unicast to this Mac
    ./rtp_send.py --iface-ip 127.0.0.1 --encoding L24 --channels 6

Documentation addresses by default (233.252.0.0/24); nothing names a real network.
"""
import argparse, math, socket, struct, time

SAP_GROUP, SAP_PORT = "239.255.255.255", 9875


def sdp(name, origin, dest, port, pt, encoding, rate, channels, ptime, rtpmap):
    lines = ["v=0", f"o=- 1 1 IN IP4 {origin}", f"s={name}", f"c=IN IP4 {dest}", "t=0 0",
             f"m=audio {port} RTP/AVP {pt}"]
    if rtpmap:
        lines.append(f"a=rtpmap:{pt} {encoding}/{rate}/{channels}")
    lines.append(f"a=ptime:{ptime:g}")
    # Deliberately no a=ts-refclk and no a=mediaclk: that is what makes it "plain" RTP.
    return "\r\n".join(lines) + "\r\n"


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--iface-ip", required=True, help="local IPv4 to send from (SAP and multicast)")
    p.add_argument("--to", help="send the RTP unicast to this IPv4 instead of to --group")
    p.add_argument("--group", default="233.252.0.110")
    p.add_argument("--port", type=int, default=5004)
    p.add_argument("--name", default="Plain RTP Test")
    p.add_argument("--encoding", choices=("L16", "L24"), default="L16")
    p.add_argument("--rate", type=int, default=48000)
    p.add_argument("--channels", type=int, default=2)
    p.add_argument("--pt", type=int, default=127, help="payload type (10/11 are the static L16/44100 types)")
    p.add_argument("--no-rtpmap", action="store_true", help="leave out a=rtpmap (only meaningful for 10/11)")
    p.add_argument("--ptime", type=float, default=4.0, help="packet time in ms")
    p.add_argument("--no-sap", action="store_true")
    p.add_argument("--seconds", type=float, default=0, help="0 = until Ctrl-C")
    a = p.parse_args()
    if a.pt in (10, 11) and a.no_rtpmap:
        a.encoding, a.rate, a.channels = "L16", 44100, 2 if a.pt == 10 else 1

    dest = a.to or a.group
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(a.iface_ip))
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 1)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 1)

    body = sdp(a.name, a.iface_ip, dest, a.port, a.pt, a.encoding, a.rate, a.channels, a.ptime,
               not a.no_rtpmap)
    sap = struct.pack("!BBH", 0x20, 0x00, 0x4712) + socket.inet_aton(a.iface_ip) \
        + b"application/sdp\x00" + body.encode()

    width = 2 if a.encoding == "L16" else 3
    frames = int(a.rate * a.ptime / 1000)
    full = (1 << (8 * width - 1)) - 1
    seq, ts, n, sent = 0, 0, 0, 0
    ssrc = 0x0DE7E57A
    start = time.monotonic()
    next_sap = start
    period = frames / a.rate
    print(f"RTP {a.encoding}/{a.rate}/{a.channels} PT {a.pt}, {frames} frames a packet, to {dest}:{a.port}"
          + ("" if a.no_sap else ", announced over SAP"))
    try:
        while not a.seconds or time.monotonic() - start < a.seconds:
            now = time.monotonic()
            if not a.no_sap and now >= next_sap:
                s.sendto(sap, (SAP_GROUP, SAP_PORT))
                next_sap = now + 1.0
            payload = bytearray()
            for f in range(frames):
                t = (n + f) / a.rate
                for c in range(a.channels):
                    v = int(0.25 * full * math.sin(2 * math.pi * (440 + 110 * c) * t))
                    payload += v.to_bytes(width, "big", signed=True)
            header = struct.pack("!BBHII", 0x80, a.pt & 0x7F, seq & 0xFFFF, ts & 0xFFFFFFFF, ssrc)
            s.sendto(header + payload, (dest, a.port))
            seq += 1
            ts += frames
            n += frames
            sent += 1
            delay = start + sent * period - time.monotonic()
            if delay > 0:
                time.sleep(delay)
    except KeyboardInterrupt:
        pass
    if not a.no_sap:
        bye = struct.pack("!BBH", 0x24, 0x00, 0x4712) + socket.inet_aton(a.iface_ip) \
            + b"application/sdp\x00" + body.encode()
        s.sendto(bye, (SAP_GROUP, SAP_PORT))
    print(f"sent {sent} packets")


if __name__ == "__main__":
    main()
