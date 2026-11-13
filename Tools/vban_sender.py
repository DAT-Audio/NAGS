#!/usr/bin/env python3
"""Fake VBAN sender for testing Network Audio Grabber's VBAN receive without Voicemeeter.

Sends a sine per channel as plain VBAN audio, the way Voicemeeter does. Host-local by default
(127.0.0.1), so nothing leaves the machine. Switch VBAN on in Settings -> Discovery first, or
run the self-test with --vban.

    ./vban_sender.py                                  # stereo i16 48 k, "Test VBAN"
    ./vban_sender.py --format f32 --channels 6 --rate 44100
    ./vban_sender.py --dest 192.0.2.255 --broadcast # to the LAN, like Voicemeeter can

Abuse modes, for checking the receiver's limits rather than its audio:

    ./vban_sender.py --fuzz        # random, truncated and lying headers; nothing may decode
    ./vban_sender.py --flood 200   # 200 made-up stream names; at most 32 may be listed
    ./vban_sender.py --flap        # a stream that keeps changing format
"""

import argparse
import math
import os
import random
import socket
import struct
import time

RATES = [6000, 12000, 24000, 48000, 96000, 192000, 384000, 8000, 16000, 32000, 64000,
         128000, 256000, 512000, 11025, 22050, 44100, 88200, 176400, 352800, 705600]
FORMATS = {"i16": (1, 2), "i24": (2, 3), "i32": (3, 4), "f32": (4, 4), "f64": (5, 8)}


def header(name, rate, frames, channels, fmt, counter):
    code, _ = FORMATS[fmt]
    return (b"VBAN" + bytes([RATES.index(rate) & 0x1F, frames - 1, channels - 1, code])
            + name.encode("ascii", "replace")[:16].ljust(16, b"\0")
            + struct.pack("<I", counter & 0xFFFFFFFF))


def sample(fmt, v):
    """v in -1..1, little-endian."""
    if fmt == "i16":
        return struct.pack("<h", int(v * 32767))
    if fmt == "i24":
        return struct.pack("<i", int(v * 8388607))[:3]
    if fmt == "i32":
        return struct.pack("<i", int(v * 2147483647))
    if fmt == "f32":
        return struct.pack("<f", v)
    return struct.pack("<d", v)


def frames_per_packet(channels, fmt):
    """As many as fit in 1436 bytes, at most 256 — what a VBAN sender does."""
    return max(1, min(256, 1436 // (channels * FORMATS[fmt][1])))


def tone(args, sock, dest):
    frames = args.frames or frames_per_packet(args.channels, args.fmt)
    peak = args.level
    freqs = [round(args.base_freq * (1 + 0.25 * ch)) for ch in range(args.channels)]
    print(f"VBAN '{args.name}' -> {dest[0]}:{dest[1]}  {args.fmt} {args.channels} ch "
          f"{args.rate} Hz, {frames} frames/packet")
    one_second = [b"".join(sample(args.fmt, peak * math.sin(2 * math.pi * f * n / args.rate))
                           for f in freqs) for n in range(args.rate)]
    frame_bytes = args.channels * FORMATS[args.fmt][1]
    pcm = b"".join(one_second)
    pcm += pcm[: frames * frame_bytes]
    period = frames / args.rate
    counter, offset, start = 0, 0, time.perf_counter()
    next_packet = start
    while not args.seconds or time.perf_counter() - start < args.seconds:
        now = time.perf_counter()
        while next_packet <= now:
            payload = pcm[offset:offset + frames * frame_bytes]
            if not (args.drop and random.random() < args.drop):
                sock.sendto(header(args.name, args.rate, frames, args.channels, args.fmt,
                                   counter) + payload, dest)
            counter += 1
            offset = (offset + frames * frame_bytes) % (args.rate * frame_bytes)
            next_packet += period
            if next_packet < now - 0.1:
                next_packet = now
        time.sleep(0.0005)
    print(f"Stopped after {counter} packets.")


def fuzz(args, sock, dest):
    """Everything a hostile or broken sender might put on the port."""
    good = header("Fuzz", 48000, 64, 2, "i16", 0) + bytes(64 * 2 * 2)
    cases = 0
    start = time.perf_counter()
    while time.perf_counter() - start < (args.seconds or 10):
        kind = random.randrange(8)
        if kind == 0:
            pkt = os.urandom(random.randrange(0, 1500))                    # noise
        elif kind == 1:
            pkt = good[:random.randrange(0, len(good))]                    # truncated
        elif kind == 2:
            pkt = good + os.urandom(random.randrange(1, 64))               # overlong
        elif kind == 3:
            pkt = bytearray(good); pkt[4] = random.randrange(21, 32)       # bad rate index
        elif kind == 4:
            pkt = bytearray(good); pkt[4] |= random.choice([0x20, 0x40, 0x60])  # not audio
        elif kind == 5:
            pkt = bytearray(good); pkt[7] = random.choice([0, 6, 7, 0x10, 0xF1])  # format
        elif kind == 6:
            pkt = bytearray(good); pkt[5] = 255; pkt[6] = 255              # header lies
        else:
            pkt = b"VBAN" + os.urandom(random.randrange(24, 1500))         # random header
        sock.sendto(bytes(pkt), dest)
        cases += 1
        time.sleep(0.0002)
    print(f"Sent {cases} malformed packets.")


def flood(args, sock, dest):
    """Many made-up streams, each one valid, as fast as possible."""
    payload = bytes(16 * 2 * 2)
    start, sent = time.perf_counter(), 0
    while time.perf_counter() - start < (args.seconds or 10):
        for i in range(args.flood):
            sock.sendto(header(f"Flood {i:04d}", 48000, 16, 2, "i16", sent) + payload, dest)
            sent += 1
        time.sleep(0.001)
    print(f"Sent {sent} packets across {args.flood} names.")


def flap(args, sock, dest):
    """One name whose format changes every 100 ms."""
    start, counter = time.perf_counter(), 0
    while time.perf_counter() - start < (args.seconds or 10):
        fmt = random.choice(list(FORMATS))
        channels = random.choice([1, 2, 6, 8])
        frames = frames_per_packet(channels, fmt)
        for _ in range(20):
            sock.sendto(header("Flapper", 48000, frames, channels, fmt, counter)
                        + bytes(frames * channels * FORMATS[fmt][1]), dest)
            counter += 1
            time.sleep(0.005)
    print(f"Sent {counter} packets.")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--dest", default="127.0.0.1")
    p.add_argument("--port", type=int, default=6980)
    p.add_argument("--broadcast", action="store_true", help="allow a broadcast --dest")
    p.add_argument("--bind", default="", help="local address to send from, to act as a second sender")
    p.add_argument("--name", default="Test VBAN")
    p.add_argument("--channels", type=int, default=2)
    p.add_argument("--rate", type=int, default=48000, choices=RATES)
    p.add_argument("--format", dest="fmt", default="i16", choices=list(FORMATS))
    p.add_argument("--frames", type=int, default=0, help="samples per packet; 0 = as many as fit")
    p.add_argument("--base-freq", type=float, default=440.0)
    p.add_argument("--level", type=float, default=0.25, help="0..1 linear")
    p.add_argument("--drop", type=float, default=0.0, help="fraction of packets to drop, 0..1")
    p.add_argument("--seconds", type=float, default=0, help="0 = run until Ctrl-C (10 s for abuse modes)")
    p.add_argument("--fuzz", action="store_true")
    p.add_argument("--flood", type=int, default=0, metavar="N")
    p.add_argument("--flap", action="store_true")
    args = p.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    if args.bind:
        sock.bind((args.bind, 0))
    if args.broadcast:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    dest = (args.dest, args.port)
    try:
        if args.fuzz:
            fuzz(args, sock, dest)
        elif args.flood:
            flood(args, sock, dest)
        elif args.flap:
            flap(args, sock, dest)
        else:
            tone(args, sock, dest)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
