#!/usr/bin/env python3
"""Acceptance tests for the Sender's offer handshake.

Plays a Grabber, badly on purpose, against a running Network Audio Sender that is offering:

    NetworkAudioSender --selftest --tone --offer --no-ask --seconds 150 &
    ./vban_offer_test.py [--sender 127.0.0.1] [--port 6981]

    NetworkAudioSender --selftest --tone --offer --allow-after 4 --seconds 40 &
    ./vban_offer_test.py --ask

`--ask` checks the default, asking Sender: a join is held (PENDING, no audio) until the Sender's
user allows it, then plays.

Needs UDP 6980 free on this Mac, so quit the Grabber first. Everything goes to the Sender's
own address; nothing is sent anywhere else. Exits 1 if any check fails.

    ./vban_offer_test.py --grabber-fuzz [--seconds 20]

The other way round: floods a running Grabber on this Mac (VBAN on) with forged beacons under
made-up names, stray CHALLENGEs and OFFERs, and malformed service packets, to 127.0.0.1:6980.
Check afterwards that it is still running and lists at most 8 streams from this address.
"""
import argparse, os, random, socket, struct, sys, time

MAGIC, VERSION, SERVICE = b"NAGS", 1, 0x4E
BEACON, SUBSCRIBE, CHALLENGE, CONFIRM, OFFER, KEEPALIVE, UNSUBSCRIBE, PENDING, DECLINED = range(1, 10)
T_NONCE, T_COOKIE, T_NAME, T_FORMAT, T_PORT, T_PAD = range(1, 7)


def packet(kind, fields, pad_to=0, name=b"test"):
    head = b"VBAN" + bytes([0x60, SERVICE, 0, 0]) + name.ljust(16, b"\0")[:16] + b"\0\0\0\0"
    body = MAGIC + bytes([VERSION, kind])
    for tag, value in fields:
        body += bytes([tag, len(value)]) + value
    out = head + body
    if pad_to and len(out) < pad_to:
        out += bytes([T_PAD, pad_to - len(out) - 2]) + b"\0" * (pad_to - len(out) - 2)
    return out


def parse(data):
    """(kind, {tag: value}) for one of ours, else None."""
    if len(data) < 34 or data[:4] != b"VBAN" or data[4] & 0xE0 != 0x60 or data[5] != SERVICE:
        return None
    if data[28:32] != MAGIC or data[32] != VERSION:
        return None
    fields, i = {}, 34
    while i + 2 <= len(data):
        tag, n = data[i], data[i + 1]
        fields[tag] = data[i + 2:i + 2 + n]
        i += 2 + n
    return data[33], fields


def is_audio(data):
    return len(data) > 28 and data[:4] == b"VBAN" and data[4] & 0xE0 == 0


class Grabber:
    """One fake Grabber: a socket, bound to 6980 unless told otherwise."""
    def __init__(self, sender, port=6980):
        self.sender = sender
        self.s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.s.bind(("0.0.0.0", port))
        self.s.settimeout(0.2)

    def send(self, data):
        self.s.sendto(data, self.sender)

    def collect(self, seconds):
        """Every datagram for `seconds`: (control messages, audio packet count)."""
        control, audio, end = [], 0, time.time() + seconds
        while time.time() < end:
            try:
                data, _ = self.s.recvfrom(2048)
            except socket.timeout:
                continue
            if is_audio(data):
                audio += 1
            else:
                m = parse(data)
                if m:
                    control.append(m)
        return control, audio

    def challenge(self, nonce, name=b"FakeGrabber"):
        self.send(packet(SUBSCRIBE, [(T_NONCE, nonce), (T_NAME, name)], pad_to=128))
        for kind, f in self.collect(1.5)[0]:
            if kind == CHALLENGE and f.get(T_NONCE) == nonce:
                return f[T_COOKIE]
        return None

    def join(self, name=b"FakeGrabber"):
        nonce = os.urandom(8)
        cookie = self.challenge(nonce, name)
        if cookie is None:
            return None
        self.send(packet(CONFIRM, [(T_NONCE, nonce), (T_COOKIE, cookie), (T_NAME, name)]))
        return cookie


results = []


def check(what, ok, detail=""):
    results.append(ok)
    print(("PASS  " if ok else "FAIL  ") + what + (f"   ({detail})" if detail else ""))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sender", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=6981)
    ap.add_argument("--grabber-fuzz", action="store_true")
    ap.add_argument("--ask", action="store_true")
    ap.add_argument("--seconds", type=float, default=20)
    a = ap.parse_args()
    if a.grabber_fuzz:
        grabber_fuzz(a.seconds)
        return
    sender = (a.sender, a.port)
    if a.ask:
        ask_checks(sender)
        return
    g = Grabber(sender)

    control, _ = g.collect(2.5)
    beacons = [f for k, f in control if k == BEACON]
    check("a beacon arrives while offering", bool(beacons),
          beacons and f"stream {beacons[0].get(T_NAME, b'?').decode(errors='replace')}")

    # 1. Too short to be a SUBSCRIBE: no reply, so a reply is never bigger than a request.
    g.send(packet(SUBSCRIBE, [(T_NONCE, os.urandom(8))]))
    control, _ = g.collect(1.5)
    check("a short SUBSCRIBE gets no CHALLENGE", not any(k == CHALLENGE for k, _ in control))

    # 2. Wrong cookie: no OFFER, no audio.
    nonce = os.urandom(8)
    cookie = g.challenge(nonce)
    check("a proper SUBSCRIBE gets a CHALLENGE", cookie is not None)
    g.send(packet(CONFIRM, [(T_NONCE, nonce), (T_COOKIE, bytes(16))]))
    control, audio = g.collect(2)
    check("a wrong cookie gets no OFFER and no audio",
          not any(k == OFFER for k, _ in control) and audio == 0, f"{audio} audio packets")

    # 3. The right cookie from another port: it is bound to the address it was sent to.
    other = Grabber(sender, port=0)
    if cookie:
        other.send(packet(CONFIRM, [(T_NONCE, nonce), (T_COOKIE, cookie)]))
    c2, a2 = other.collect(2)
    _, a1 = g.collect(0.5)
    check("a cookie replayed from another port is refused", a2 == 0 and a1 == 0 and not any(k == OFFER for k, _ in c2),
          f"{a2 + a1} audio packets")
    other.s.close()

    # 4. A proper join: OFFER, then audio here.
    time.sleep(10.5)                                  # let the per-address SUBSCRIBE window clear
    cookie = g.join()
    control, audio = g.collect(2)
    check("a proper join gets an OFFER and audio", any(k == OFFER for k, _ in control) and audio > 100,
          f"{audio} audio packets in 2 s")

    # 5. A forged UNSUBSCRIBE (wrong cookie) changes nothing; the real one stops it at once.
    g.send(packet(UNSUBSCRIBE, [(T_COOKIE, bytes(16))]))
    _, audio = g.collect(1.5)
    check("a forged UNSUBSCRIBE is ignored", audio > 100, f"{audio} audio packets")
    g.send(packet(KEEPALIVE, [(T_COOKIE, cookie), (T_NAME, b"Renamed")]))
    g.send(packet(UNSUBSCRIBE, [(T_COOKIE, cookie)]))
    g.collect(0.5)
    _, audio = g.collect(1.5)
    check("the real UNSUBSCRIBE stops the audio", audio == 0, f"{audio} audio packets")

    # 6. No keepalive: dropped after 15 s. The Sender prunes on a once-a-second tick, so the drop
    # lands between 15 and 16 s; counting from 15.5 s failed about one run in two.
    time.sleep(10.5)
    g.join()
    _, audio = g.collect(1)
    started = audio > 50
    g.collect(15.5)
    _, audio = g.collect(2)
    check("a silent subscriber is dropped after 15 s", started and audio == 0, f"{audio} audio packets at 16.5–18.5 s")

    # 7. Rate limit: ten SUBSCRIBEs at once get at most four CHALLENGEs.
    time.sleep(10.5)
    for _ in range(10):
        g.send(packet(SUBSCRIBE, [(T_NONCE, os.urandom(8))], pad_to=128))
    control, _ = g.collect(1.5)
    n = sum(1 for k, _ in control if k == CHALLENGE)
    check("SUBSCRIBEs are rate-limited per address", n <= 4, f"{n} CHALLENGEs for 10")

    # 8. Garbage of every shape, then a proper join still works.
    for _ in range(3000):
        kind = random.randint(0, 9)
        fields = [(random.randint(0, 9), os.urandom(random.randint(0, 40))) for _ in range(random.randint(0, 6))]
        data = bytearray(packet(kind, fields))
        for _ in range(random.randint(0, 4)):
            data[random.randrange(len(data))] = random.randrange(256)
        g.send(bytes(data[:random.randint(0, len(data))]))
    time.sleep(10.5)
    cookie = g.join()
    control, audio = g.collect(2)
    check("after 3000 malformed packets the Sender still answers", audio > 100, f"{audio} audio packets")
    if cookie:
        g.send(packet(UNSUBSCRIBE, [(T_COOKIE, cookie)]))

    # 9. At most eight listen at once: the ninth gets no OFFER. Joins are spaced out, since
    # SUBSCRIBE is rate-limited per address.
    g.collect(1)
    crowd = []
    for i in range(9):
        if i and i % 4 == 0:
            time.sleep(10.5)
        extra = Grabber(sender, port=0)
        cookie = extra.join(name=b"Crowd%d" % i)
        control, audio = extra.collect(1)
        crowd.append((extra, cookie, any(k == OFFER for k, _ in control), audio))
        for other, c, _, _ in crowd:                 # keep the earlier ones alive
            if c:
                other.send(packet(KEEPALIVE, [(T_COOKIE, c)]))
    admitted = [ok for _, _, ok, _ in crowd]
    check("at most 8 subscribers: the 9th is refused", admitted[:8] == [True] * 8 and not admitted[8],
          f"offers {admitted.count(True)} of 9")
    for extra, c, _, _ in crowd:
        if c:
            extra.send(packet(UNSUBSCRIBE, [(T_COOKIE, c)]))
        extra.s.close()

    failed = results.count(False)
    print(f"{len(results) - failed} of {len(results)} passed.")
    sys.exit(1 if failed else 0)


def ask_checks(sender):
    g = Grabber(sender)
    nonce = os.urandom(8)
    cookie = g.challenge(nonce, name=b"AskingGrabber")
    check("an asking Sender still sends a CHALLENGE", cookie is not None)
    g.send(packet(CONFIRM, [(T_NONCE, nonce), (T_COOKIE, cookie), (T_NAME, b"AskingGrabber")]))
    control, audio = g.collect(1.5)
    check("a new Grabber is held: PENDING, no OFFER, no audio",
          any(k == PENDING for k, _ in control) and not any(k == OFFER for k, _ in control) and audio == 0,
          f"{audio} audio packets")
    # Keep confirming on the same cookie, as the Grabber does, until the Sender's user allows it.
    offered, started = False, time.time()
    while time.time() - started < 12 and not offered:
        g.send(packet(CONFIRM, [(T_NONCE, nonce), (T_COOKIE, cookie), (T_NAME, b"AskingGrabber")]))
        control, _ = g.collect(1)
        offered = any(k == OFFER for k, _ in control)
    _, audio = g.collect(1.5)
    check("once allowed, it gets an OFFER and audio", offered and audio > 100,
          f"after {time.time() - started:.0f} s, {audio} audio packets")
    g.send(packet(UNSUBSCRIBE, [(T_COOKIE, cookie)]))
    failed = results.count(False)
    print(f"{len(results) - failed} of {len(results)} passed.")
    sys.exit(1 if failed else 0)


def grabber_fuzz(seconds):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    to = ("127.0.0.1", 6980)
    fmt = struct.pack("<IHB", 48000, 2, 1)
    sent, end = 0, time.time() + seconds
    while time.time() < end:
        r = random.random()
        if r < 0.4:      # a beacon under a new made-up name every time
            name = ("Fake%06d" % random.randrange(10**6)).encode()
            data = packet(BEACON, [(T_NAME, name), (T_FORMAT, fmt), (T_PORT, struct.pack("<H", 6981))])
        elif r < 0.6:    # handshake replies nobody asked for
            data = packet(random.choice([CHALLENGE, OFFER]),
                          [(T_NONCE, os.urandom(8)), (T_COOKIE, os.urandom(16)),
                           (T_NAME, b"Forged"), (T_FORMAT, fmt)])
        else:            # anything at all, cut short and bit-flipped
            data = bytearray(packet(random.randint(0, 9),
                                    [(random.randint(0, 9), os.urandom(random.randint(0, 40)))
                                     for _ in range(random.randint(0, 5))]))
            for _ in range(random.randint(0, 4)):
                data[random.randrange(len(data))] = random.randrange(256)
            data = bytes(data[:random.randint(0, len(data))])
        s.sendto(data, to)
        sent += 1
        if sent % 200 == 0:
            time.sleep(0.01)
    print(f"sent {sent} packets to 127.0.0.1:6980 in {seconds:.0f} s")


if __name__ == "__main__":
    main()
