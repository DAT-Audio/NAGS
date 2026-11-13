#!/usr/bin/env python3
"""Many fake AES67 streams from one process, for measuring the Grabber with lots of sources.

    ./many_senders.py --count 32                 # on this Mac only (lo0); run the Grabber with
                                                 # AES67_SHOW_LOOPBACK=1 and pick lo0

Streams on 233.252.0.(10+i):5004 (documentation range), named "Bench NN", announced over SAP.
Every fourth stream is 8 channels, the rest stereo; L24/48 kHz, 1 ms packets by default. One
process rather than one per stream, so the senders do not swamp the Mac being measured (one
Python process holds ~32 streams at 1 ms before it saturates a core). Built on test_sender.py.
"""
import argparse, importlib.util, math, os, socket, struct, sys, time
spec = importlib.util.spec_from_file_location("ts", os.path.join(os.path.dirname(os.path.abspath(__file__)), "test_sender.py"))
ts = importlib.util.module_from_spec(spec); spec.loader.exec_module(ts)
p = argparse.ArgumentParser(); p.add_argument("--iface-ip", default="127.0.0.1")
p.add_argument("--count", type=int, default=16); p.add_argument("--ptime", type=float, default=1.0)
p.add_argument("--seconds", type=float, default=60); a = p.parse_args()
rate = 48000; frames = int(rate * a.ptime / 1000)
sock = ts.make_socket(a.iface_ip, 1)
streams = []
for i in range(a.count):
    ch = 8 if i % 4 == 3 else 2
    group = f"233.252.0.{10 + i}"
    sdp = ts.build_sdp(f"Bench {i+1:02d}", a.iface_ip, group, 5004, ch, rate, a.ptime)
    peak = int(0.2 * 8388607); f0 = 220 + 40 * i
    pcm = bytearray()
    for n in range(rate):
        for c in range(ch):
            pcm += struct.pack("!i", int(peak * math.sin(2 * math.pi * (f0 + 30 * c) * n / rate)))[1:]
    pcm = bytes(pcm + pcm[:frames * ch * 3])
    streams.append(dict(group=group, sap=ts.build_sap(sdp, a.iface_ip), pcm=pcm, ch=ch,
                        loop=rate * ch * 3, size=frames * ch * 3, seq=0, tsv=0, off=0, ssrc=0x5AE68000 + i))
start = time.perf_counter(); nxt = start; nsap = start; period = frames / rate
while time.perf_counter() - start < a.seconds:
    now = time.perf_counter()
    if now >= nsap:
        for s in streams: sock.sendto(s["sap"], (ts.SAP_GROUP, ts.SAP_PORT))
        nsap = now + 5
    while nxt <= now:
        for s in streams:
            h = struct.pack("!BBHII", 0x80, ts.PAYLOAD_TYPE, s["seq"], s["tsv"], s["ssrc"])
            sock.sendto(h + s["pcm"][s["off"]:s["off"] + s["size"]], (s["group"], 5004))
            s["seq"] = (s["seq"] + 1) & 0xFFFF; s["tsv"] = (s["tsv"] + frames) & 0xFFFFFFFF
            s["off"] = (s["off"] + s["size"]) % s["loop"]
        nxt += period
        if nxt < now - 0.1: nxt = now
    time.sleep(max(0, min(0.0005, nxt - time.perf_counter())))
