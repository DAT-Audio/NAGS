#!/usr/bin/env python3
"""Fake AES67 sender for testing Network Audio Grabber without any hardware.

Announces a session over SAP and transmits an L24/48k RTP stream carrying a different
sine tone on each channel.

Host-local test: send over the loopback interface, so nothing touches a shared network.
Launch the app with AES67_SHOW_LOOPBACK=1 so lo0 appears in its interface list.

    ./test_sender.py --iface-ip 127.0.0.1

Real network test: send from the audio NIC, where other devices can subscribe too.

    ./test_sender.py --iface-ip 192.0.2.20
"""

import argparse
import math
import socket
import struct
import time

PAYLOAD_TYPE = 98
SAP_GROUP = "239.255.255.255"
SAP_PORT = 9875


def build_sdp(name, source_ip, group, port, channels, rate, ptime_ms):
    session_id = int(time.time())
    return (
        "v=0\r\n"
        f"o=- {session_id} {session_id} IN IP4 {source_ip}\r\n"
        f"s={name}\r\n"
        f"c=IN IP4 {group}/32\r\n"
        "t=0 0\r\n"
        "a=clock-domain:PTPv2 0\r\n"
        f"m=audio {port} RTP/AVP {PAYLOAD_TYPE}\r\n"
        f"c=IN IP4 {group}/32\r\n"
        "a=rtpmap:%d L24/%d/%d\r\n" % (PAYLOAD_TYPE, rate, channels)
        + "a=sync-time:0\r\n"
        "a=framecount:%d\r\n" % int(rate * ptime_ms / 1000)
        + f"a=ptime:{ptime_ms:g}\r\n"
        "a=mediaclk:direct=0\r\n"
        "a=ts-refclk:ptp=IEEE1588-2008:00-00-5E-EF-10-00-00-00:0\r\n"
        "a=recvonly\r\n"
    )


def build_sap(sdp, source_ip):
    header = struct.pack("!BBH", 0x20, 0x00, 0x4711)      # v=1, announce, no auth
    header += socket.inet_aton(source_ip)
    return header + b"application/sdp\x00" + sdp.encode("utf-8")


def make_socket(iface_ip, ttl):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(iface_ip))
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, ttl)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 1)
    return s


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--iface-ip", required=True, help="local IPv4 of the NIC to send from")
    p.add_argument("--group", default="233.252.0.100")
    p.add_argument("--port", type=int, default=5004)
    p.add_argument("--name", default="Test Tone Bus")
    p.add_argument("--channels", type=int, default=2)
    p.add_argument("--rate", type=int, default=48000)
    p.add_argument("--ptime", type=float, default=1.0, help="packet time in ms")
    p.add_argument("--base-freq", type=float, default=440.0)
    p.add_argument("--level", type=float, default=0.25, help="0..1 linear")
    # macOS does not loop TTL-0 multicast back to local sockets, so 1 is the usable minimum;
    # with --iface-ip 127.0.0.1 the traffic still never leaves the machine.
    p.add_argument("--ttl", type=int, default=1, help="1 = local segment (default)")
    p.add_argument("--seconds", type=float, default=0, help="0 = run until Ctrl-C")
    p.add_argument("--active-channels", default="",
                   help="comma-separated 1-based channels to put tone on; others stay silent")
    args = p.parse_args()

    frames = max(1, int(round(args.rate * args.ptime / 1000)))
    sdp = build_sdp(args.name, args.iface_ip, args.group, args.port,
                    args.channels, args.rate, args.ptime)
    sap_packet = build_sap(sdp, args.iface_ip)

    sock = make_socket(args.iface_ip, args.ttl)
    print(f"Announcing '{args.name}' -> {args.group}:{args.port} "
          f"(L24 {args.channels}ch {args.rate}Hz {args.ptime:g}ms, TTL {args.ttl})")
    print("Ctrl-C to stop.")

    # One second of interleaved L24 is precomputed and looped. Integer frequencies make the
    # loop point seamless, and it keeps Python fast enough to sustain 1 ms packets.
    peak = int(args.level * 8388607)
    freqs = [round(args.base_freq * (1 + 0.25 * ch)) for ch in range(args.channels)]
    print("Tones     : " + ", ".join(f"ch{i+1} {f} Hz" for i, f in enumerate(freqs)))
    active = ({int(c) - 1 for c in args.active_channels.split(",") if c.strip()}
              if args.active_channels else set(range(args.channels)))
    print("Active ch : " + ", ".join(str(c + 1) for c in sorted(active)))
    pcm = bytearray()
    for n in range(args.rate):
        for ch in range(args.channels):
            v = int(peak * math.sin(2 * math.pi * freqs[ch] * n / args.rate)) if ch in active else 0
            pcm += struct.pack("!i", v)[1:]          # top 3 bytes = 24-bit big-endian
    pcm = bytes(pcm + pcm[: frames * args.channels * 3])   # pad so every slice is contiguous
    loop_bytes = args.rate * args.channels * 3
    packet_bytes = frames * args.channels * 3

    seq = 0
    timestamp = 0
    offset = 0
    ssrc = 0x5AE67001

    start = time.perf_counter()
    next_packet = start
    next_sap = start
    period = frames / args.rate

    try:
        while True:
            now = time.perf_counter()
            if args.seconds and now - start >= args.seconds:
                break

            if now >= next_sap:
                sock.sendto(sap_packet, (SAP_GROUP, SAP_PORT))
                next_sap = now + 5.0

            # Send everything that has come due, then yield briefly.
            if next_packet > now + 1.0:
                next_packet = now                      # clock went backwards; resynchronise
            while next_packet <= now:
                header = struct.pack("!BBHII", 0x80, PAYLOAD_TYPE, seq, timestamp, ssrc)
                sock.sendto(header + pcm[offset:offset + packet_bytes], (args.group, args.port))
                seq = (seq + 1) & 0xFFFF
                timestamp = (timestamp + frames) & 0xFFFFFFFF
                offset = (offset + packet_bytes) % loop_bytes
                next_packet += period
                if next_packet < now - 0.1:            # fell badly behind; skip ahead
                    next_packet = now
            time.sleep(0.0002)
    except KeyboardInterrupt:
        pass
    finally:
        # Deletion announcement so receivers drop the session promptly.
        delete = struct.pack("!BBH", 0x24, 0x00, 0x4711) + socket.inet_aton(args.iface_ip)
        sock.sendto(delete + b"application/sdp\x00" + sdp.encode(), (SAP_GROUP, SAP_PORT))
        sock.close()
        print(f"\nStopped after {seq} packets.")


if __name__ == "__main__":
    main()
