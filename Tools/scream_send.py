#!/usr/bin/env python3
"""A fake Scream sender, for testing the Grabber's Scream receiver without a Windows PC.

Sends a stereo tone (440 Hz left, 660 Hz right, about -12 dBFS) in Scream's format: UDP to
239.255.77.77:4010 by default, each datagram a 5-byte header and up to 1152 bytes of
little-endian PCM. Written from the protocol description in Scream's README
(github.com/duncanthrax/scream); no Scream code is used.

    ./scream_send.py --iface-ip 127.0.0.1                  # multicast on this Mac only
    ./scream_send.py --to 127.0.0.1                        # unicast
    ./scream_send.py --iface-ip 127.0.0.1 --bits 24 --rate 96000 --channels 6

Stop with Ctrl-C, or --seconds N.
"""
import argparse, math, socket, struct, sys, time

GROUP, PORT = "239.255.77.77", 4010


def header(rate, bits, channels, mask):
    if rate % 44100 == 0:
        base, mult = 0x80, rate // 44100
    elif rate % 48000 == 0:
        base, mult = 0x00, rate // 48000
    else:
        sys.exit(f"Scream carries multiples of 44.1 or 48 kHz, not {rate}")
    return struct.pack("<BBBH", base | mult, bits, channels, mask)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--iface-ip", help="local IPv4 of the interface to send the multicast from")
    p.add_argument("--to", help="send unicast to this IPv4 instead of the multicast group")
    p.add_argument("--port", type=int, default=PORT)
    p.add_argument("--rate", type=int, default=48000)
    p.add_argument("--bits", type=int, default=16, choices=(16, 24, 32))
    p.add_argument("--channels", type=int, default=2)
    p.add_argument("--seconds", type=float, default=0, help="0 = until Ctrl-C")
    a = p.parse_args()

    width = a.bits // 8
    frames = 1152 // (width * a.channels)
    head = header(a.rate, a.bits, a.channels, 0x3 if a.channels == 2 else 0)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    if a.to:
        dest = (a.to, a.port)
    else:
        if not a.iface_ip:
            sys.exit("give --iface-ip for multicast, or --to for unicast")
        s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(a.iface_ip))
        s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 1)
        s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 1)
        dest = (GROUP, a.port)

    full = (1 << (a.bits - 1)) - 1
    n, sent, start = 0, 0, time.monotonic()
    period = frames / a.rate
    print(f"Scream: {a.rate} Hz, {a.bits}-bit, {a.channels} ch, {frames} frames a packet, to {dest[0]}:{dest[1]}")
    try:
        while not a.seconds or time.monotonic() - start < a.seconds:
            body = bytearray()
            for f in range(frames):
                t = (n + f) / a.rate
                for c in range(a.channels):
                    v = int(0.25 * full * math.sin(2 * math.pi * (440 + 220 * c) * t))
                    body += v.to_bytes(width, "little", signed=True)
            s.sendto(head + body, dest)
            n += frames
            sent += 1
            # Paced against the start, so the rate does not drift with the loop's own cost.
            delay = start + sent * period - time.monotonic()
            if delay > 0:
                time.sleep(delay)
    except KeyboardInterrupt:
        pass
    print(f"sent {sent} packets")


if __name__ == "__main__":
    main()
