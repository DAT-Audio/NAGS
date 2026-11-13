# Network Audio wire protocol — version 1, and version 2 for the Remote link

The contract between **Network Audio Sender**, the **Grabber's Send**, the **Grabber** and the
**DAT Audio plugins**, on any platform. A Windows (or any other) build must read and write exactly
this; §9's sample packets are made by the Mac apps' own encoders and checked on every
`NetworkAudioGrabber --checkvban`, so this document and the code cannot drift apart unnoticed.

*Written from the code, and kept in step with it. It describes what is built.*

**Not covered here:** the standard protocols the Grabber also receives — AES67/RAVENNA (RTP,
SAP/SDP, RTSP, mDNS), Dante in AES67 mode, Scream, plain RTP, Icecast/HTTP — which follow their
own published specifications.

**Conventions.** All multi-byte numbers are **little-endian**, as in VBAN. "Sender" means any
sending end (the Sender app, the Grabber's Send, the Sender plugin); "Grabber" any receiving end
(the app or the Grabber plugin). IPv4 only. All addresses in this document are from the
documentation ranges.

---

## 1. Transport and ports

| What | Where |
|---|---|
| Audio | plain VBAN over UDP (§2), Sender → each listener's address **and port** |
| Grabber's VBAN port | UDP **6980**, all interfaces. A second Grabber on the same machine binds a spare port and also binds each local broadcast address on 6980 (`SO_REUSEADDR`+`SO_REUSEPORT`) to hear beacons; it reuses the same spare port across restarts. |
| Sender's control port | UDP **6981**, or the next free one if another Sender holds it. **Audio leaves from this same socket**, and every control message is sent from and to it. |
| Beacons | Sender → the broadcast address of each local network it offers on, port 6980 (127.0.0.1:6980 if it has none) |

A Grabber sends every control message from the socket it receives audio on, so the address and
port a Sender sees on a SUBSCRIBE is where the audio goes.

## 2. Audio: plain VBAN

Standard VBAN audio, so Voicemeeter and VBAN Receptor play it too:

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | `56 42 41 4E` ("VBAN") |
| 4 | 1 | sub-protocol `0x00` (high 3 bits) + sample-rate index (low 5 bits) |
| 5 | 1 | frames per packet − 1 (1…256) |
| 6 | 1 | channels − 1 (1…256) |
| 7 | 1 | codec `0x0` PCM (high 4 bits) + data type (low 3 bits): 1 i16, 2 i24, 3 i32, 4 f32, 5 f64 |
| 8 | 16 | stream name: printable ASCII, zero-padded, not necessarily terminated |
| 24 | 4 | frame counter, +1 per packet, wraps |
| 28 | … | interleaved samples, little-endian; payload ≤ 1436 bytes |

Sample-rate index: 6000, 12000, 24000, 48000, 96000, 192000, 384000, 8000, 16000, 32000, 64000,
128000, 256000, 512000, 11025, 22050, 44100, 88200, 176400, 352800, 705600 (21–31 invalid).

- **A receiver accepts a packet only if** its length is exactly 28 + frames × channels × bytes per
  sample, the codec is PCM, the data type is 1–5 and the rate index is valid. 8-bit and the packed
  12/10-bit types are refused.
- **A Sender packs** as many frames as fit (at most 256 and 1436 bytes: stereo i16 = 256 frames,
  stereo i24 = 239), clips float to ±1 before integer conversion (i16 × 32767, i24 × 8 388 607,
  i32 × 2 147 483 647), and zeroes NaN/∞ in float types.
- **A stream's identity is `vban:<source IP>/<name>`.** Format is not part of it: a format change
  is the same stream reconfiguring.
- **Silence keeps a listener.** While a Sender has destinations and capture has delivered nothing
  for 60 ms, it sends silence every 20 ms at the last rate and channel count, so a Grabber does
  not see the stream vanish on a quiet machine. A muted destination also gets silence, not nothing.
- Names: what a user types becomes printable ASCII (others → `?`), cut to 16 bytes, trimmed.

## 3. Control messages

Carried in **VBAN service packets** (sub-protocol `0x60`), which a plain VBAN receiver ignores —
not the VBAN text sub-protocol, which Voicemeeter reads as remote-control commands.

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | "VBAN" |
| 4 | 1 | `0x60` (service) |
| 5 | 1 | service type **`0x4E`** |
| 6 | 2 | `00 00` |
| 8 | 16 | a name, for packet sniffers only (the sender's stream or Grabber name); never read |
| 24 | 4 | `00 00 00 00` |
| 28 | 4 | magic `4E 41 47 53` ("NAGS") |
| 32 | 1 | protocol version: **`0x01`** |
| 33 | 1 | message type (§3.1) |
| 34 | … | fields: `tag (1) · length (1) · value (length)`, any order |

At most **512 bytes**. A packet that fails any of these, or whose fields run past its end, is not
a control message and is ignored.

### 3.1 Message types and the fields each must carry

| Type | Name | Direction | Required fields |
|---|---|---|---|
| 1 | BEACON | Sender → broadcast | name, format, port (+ instance) |
| 2 | SUBSCRIBE | Grabber → Sender | nonce; whole packet **≥ 128 bytes** (padding) |
| 3 | CHALLENGE | Sender → Grabber | nonce, cookie |
| 4 | CONFIRM | Grabber → Sender | nonce, cookie (+ name, instance) |
| 5 | OFFER | Sender → Grabber | name, format |
| 6 | KEEPALIVE | Grabber → Sender | cookie (+ name) |
| 7 | UNSUBSCRIBE | Grabber → Sender | cookie |
| 8 | PENDING | Sender → Grabber | — |
| 9 | DECLINED | Sender → Grabber | — |

A message missing a required field is ignored.

### 3.2 Fields

| Tag | Field | Length | Value |
|---|---|---|---|
| 1 | nonce | 8 | random, chosen by the Grabber per attempt |
| 2 | cookie | 16 | from the Sender (§5) |
| 3 | name | 1–16 | BEACON/OFFER: the stream's name; SUBSCRIBE/CONFIRM/KEEPALIVE: the Grabber's name (shown to the Sender's user, never trusted) |
| 4 | format | 7 | sample rate u32, channels u16 (1–256), VBAN data type u8 |
| 5 | port | 2 | BEACON: the Sender's control port (u16, non-zero) |
| 6 | padding | any | zeros; ignored |
| 7 | instance | 8 | random identity: in BEACON, the Sender's (one per stream, kept across launches); in CONFIRM, the Grabber's (kept across launches) |

**Unknown tags are skipped.** That is how fields are added without breaking older builds (the
Grabber's name, then the two uses of `instance`, were added this way). A field with a known tag
but the wrong length makes the whole packet invalid.

## 4. The exchange

```
Sender (Findable)                                   Grabber
  BEACON  ──── broadcast:6980, every 1 s ────────▶  lists vban:<ip>/<name>
                                                    user presses ▶
          ◀──────────────────────────── SUBSCRIBE  (nonce, ≥128 bytes)
  CHALLENGE (nonce, cookie) ─────────────────────▶
          ◀──────────────────────────── CONFIRM    (nonce, cookie, name, instance)
  not yet allowed, asking first:
  PENDING ───────────────────────────────────────▶  "Asking…", CONFIRM again every 3 s
  user presses Allow (or allowed before, or Ask first is off, or a Remote link end):
  OFFER (name, format) ──────────────────────────▶
  audio ─────────────── to the SUBSCRIBE's address:port ─▶
          ◀──────────────────────────── KEEPALIVE  every 5 s (cookie)
  …
          ◀──────────────────────────── UNSUBSCRIBE (cookie): stops at once
```

**Grabber rules.**
- A BEACON makes a listing; it subscribes only to a stream its user asked for.
- **One Sender, one listing:** beacons with the same `instance` from several of the Sender's
  addresses are one stream, kept under the first address heard unless a better one appears — this
  machine's own address, or one on the Grabber's chosen network — or the kept one is silent for
  5 s. A listing **whose audio is arriving is never moved or dropped** (it may be a broadcast).
- Unanswered: SUBSCRIBE again with a new nonce, waiting 1 s, then doubling to 30 s.
- After CHALLENGE: CONFIRM at once. While PENDING: CONFIRM every 3 s on the same cookie, while
  it is under 25 s old. After DECLINED: ask again every **20 s** (a Sender answers a denied
  Grabber without asking its user), so an Allow given later takes effect.
- After OFFER: KEEPALIVE every 5 s. **No audio for 4 s:** start again from SUBSCRIBE.
- An OFFER or PENDING clears a DECLINED.

**Sender rules.**
- **Answers SUBSCRIBE only with a CHALLENGE**, keeping no state. A SUBSCRIBE under 128 bytes is
  ignored, so no reply is ever larger than its request.
- Limits: **4 SUBSCRIBEs per address in any 10 s**, 20 per second from everyone (a Remote link's
  exact address and port is exempt from the per-address limit); at most **8 listeners**.
- CONFIRM with a valid cookie, then, in order: refused (DECLINED) if this Grabber was denied;
  PENDING if Ask first is on and it is not allowed; otherwise OFFER and audio starts.
- A request with no CONFIRM for 10 s is forgotten. A listener with no KEEPALIVE for **15 s** is
  dropped.
- **Findable off:** no beacons; drops every listener except Remote link ends; answers nobody but
  Remote link ends and listeners it still has.
- **No beacon to a broadcast address it is broadcasting the stream to** (that network hears the
  stream already; an offer there too would list it twice).

## 5. The cookie

`cookie = first 16 bytes of HMAC-SHA256(key, "<ip>|<port>|<bucket>")`, where `ip` is the
SUBSCRIBE's source address as dotted decimal, `port` its source port in decimal, `bucket` =
floor(Unix time / 30), and `key` is 32 random bytes made fresh each time the Sender starts. A
Sender accepts the current bucket or the one before, and compares in constant time. Only the
Sender ever checks a cookie, so another implementation may compute it any way that keeps the same
property: **only someone who received the CHALLENGE at that address and port can send it back**,
which stops a forged SUBSCRIBE turning the Sender into an amplifier against a victim.

## 6. Who may listen

- **Allowed** Grabbers are remembered by address **and**, when the Grabber gave one, by its
  `instance`. An allowed instance is let in from any of its machine's **local** addresses
  (private, CGNAT/VPN, on-link); never by instance from an internet address.
- **Denied** Grabbers are refused (by address and instance) until the Sender restarts or its user
  allows them in its settings.
- The instance is as forgeable as an address by anyone who can see a CONFIRM on the local network,
  where VBAN audio is unencrypted anyway; it is a convenience, not a credential.

## 7. Remote link

For two ends behind different routers, with nothing to set up on either router.

1. **Each end's code** comes from the socket audio uses (the Sender's control socket; the Grabber's
   VBAN socket): a STUN Binding Request (RFC 8489) to `stun.cloudflare.com:3478` from that very
   socket, the reply read in the same receive loop. **Only when the user presses the button.**
   While a code is fresh (15 minutes), the request is repeated every 15 s to keep the router's
   mapping.
2. **The code** (version 2) is 24 bytes — `0x20 | role` (1 receiving,
   2 sending), the IPv4 address (4, network order), the port (2, **big-endian**), **the end's
   secret (16)**, a check byte — in Crockford-style base32 (`0123456789ABCDEFGHJKMNPQRSTVWXYZ`,
   39 characters), shown as `NAG-` and groups of five: `NAG-XXXXX-XXXXX-…-XXXX`. Check byte: start
   at `0x5A`; for each of the 23 bytes, `c = c × 31 + byte + index` (mod 256). Reading strips a
   leading `NAG`, forgives case, spaces and dashes, and reads O/I/L as 0/1/1. **The secret** is
   random, made once per end and kept, so a new code doesn't break a link already made.
   A version 1 code (8 bytes: no secret, `0x10 | role`) is recognised and refused as made by an
   older version.
3. **The Sender**, given the receiving end's code: lets exactly that address **and port** in
   without asking (still through the cookie), and sends a **KNOCK** (`4E 41 47 4B 01`, 5 bytes)
   to it from its control socket every second for a minute, then every 15 s, so its own router
   lets that end's packets in. It works with Findable off.
4. **The Grabber**, given the sending end's code: subscribes to that address and port (§4), which
   opens its own router towards the Sender. It ignores KNOCKs.
5. Two codes with the same outside address mean both ends are behind one router, where this
   cannot work: say so, and point to *On this network*.

Everything between two linked ends is **sealed** (§7a), except the KNOCK.

## 7a. The Remote link's encryption (version 2)

**Keys.** With the sending end's secret `S` and the receiving end's `R` (from the two codes):
`k(S→R) = HKDF-SHA256(ikm: S ‖ R, salt: "NAG remote link v2", info: "sender to receiver", 32)` and
`k(R→S)` the same with info `"receiver to sender"`. Each direction has its own key.

**A sealed packet** (any datagram between linked ends: every §3 message and the §2 audio):

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | `4E 41 47 45` ("NAGE") |
| 4 | 1 | `0x02` |
| 5 | 8 | epoch: random, chosen once per run of the sealing end |
| 13 | 8 | counter, **big-endian**, from 0, +1 per packet sealed with this epoch |
| 21 | n | the packet, ChaCha20-Poly1305 (RFC 8439) ciphertext |
| 21+n | 16 | Poly1305 tag |

- **Per-epoch subkey:** `HKDF-SHA256(ikm: k(direction), salt: epoch, info: "packet", 32)`.
- **Nonce:** four zero bytes, then the counter (8, big-endian).
- **Associated data:** the 21-byte header.

A restarted end has a new epoch, so no nonce repeats under one key.

**Opening rules.**
- **From a linked end's address and port, only sealed packets are taken.** A plain packet from
  there, whether a forgery or its KNOCK, is dropped.
- A packet that fails to authenticate is dropped.
- **Replays:** each epoch keeps a 64-packet window above its highest counter, and a counter
  already seen, or more than 64 behind, is dropped. This is checked only after the packet has
  authenticated.
- **A new epoch** (the other end restarted) is taken only once the current one has been quiet for
  2 s, and old epochs are remembered, so a captured packet can't be replayed as a new run.

**Size:** sealing adds 37 bytes. While any destination is sealed, the Sender cuts its audio to at
most `1436 − 37 = 1399` bytes of payload, so every sealed datagram fits a 1500-byte MTU.

Local VBAN (§2), broadcast, Findable on this network and Senders added by address stay plain
VBAN, which Voicemeeter and other receivers can play.

## 8. Versioning

- The control messages are **version 1** (byte 32). A receiver ignores control packets of any other
  version. **Version 2** is the Remote link's sealing (§7a) and its codes (§7); inside the seal,
  the messages are version 1 as before.
- **Adding** a field: a new tag, optional; older builds skip it. No version change.
- **Changing** the meaning or layout of anything here: a new version, and both ends must say what
  they do with the other one. SRT was considered for the Remote link and not chosen:
  §7a encrypts it without a C++ dependency. SRT's resending of lost packets stays an option if
  internet loss turns out to matter.
- Service type `0x4E`: **agreed with VBAN's author, Vincent Burel (VB-Audio).** The
  service sub-protocol uses functions 0, 1, 2, 32 and 33; 0x4E is unused, and he will list it in
  the VBAN specification as used by these apps so it is not given to anything else. Our "NAGS"
  marker does not replace the VBAN header: the packet starts with the standard 28-byte header
  ("VBAN", 0x60, 0x4E, …) and "NAGS" is the first four bytes of the payload, at offset 28.

## 9. Sample packets

Made from fixed inputs — stream "Edit Suite Mac", Grabber "Control Room", nonce `11…18`,
cookie `21…30`, Sender instance `01…08`, Grabber instance `a1…a8`, 48 kHz stereo i16, port 6981 —
by `NetworkAudioSender --protocol-vectors`. SEALED uses Sender secret `01…10`, Grabber
secret `11…20`, epoch `e0…e7` and counter 0; the codes carry those secrets. An implementation must produce these bytes from the
same inputs and decode them back to the same values.

**BEACON** — Sender → broadcast:6980, every second while Findable (73 bytes)

```
0000  56 42 41 4e 60 4e 00 00 45 64 69 74 20 53 75 69
0010  74 65 20 4d 61 63 00 00 00 00 00 00 4e 41 47 53
0020  01 01 03 0e 45 64 69 74 20 53 75 69 74 65 20 4d
0030  61 63 04 07 80 bb 00 00 02 00 01 05 02 45 1b 07
0040  08 01 02 03 04 05 06 07 08
```

**SUBSCRIBE** — Grabber → Sender's control port (padded to 128 bytes) (128 bytes)

```
0000  56 42 41 4e 60 4e 00 00 43 6f 6e 74 72 6f 6c 20
0010  52 6f 6f 6d 00 00 00 00 00 00 00 00 4e 41 47 53
0020  01 02 01 08 11 12 13 14 15 16 17 18 03 0c 43 6f
0030  6e 74 72 6f 6c 20 52 6f 6f 6d 06 44 00 00 00 00
0040  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
0050  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
0060  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
0070  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

**CHALLENGE** — Sender → the SUBSCRIBE's source address and port (62 bytes)

```
0000  56 42 41 4e 60 4e 00 00 45 64 69 74 20 53 75 69
0010  74 65 20 4d 61 63 00 00 00 00 00 00 4e 41 47 53
0020  01 03 01 08 11 12 13 14 15 16 17 18 02 10 21 22
0030  23 24 25 26 27 28 29 2a 2b 2c 2d 2e 2f 30
```

**CONFIRM** — Grabber → Sender, echoing the nonce and cookie, with its identity (86 bytes)

```
0000  56 42 41 4e 60 4e 00 00 43 6f 6e 74 72 6f 6c 20
0010  52 6f 6f 6d 00 00 00 00 00 00 00 00 4e 41 47 53
0020  01 04 01 08 11 12 13 14 15 16 17 18 02 10 21 22
0030  23 24 25 26 27 28 29 2a 2b 2c 2d 2e 2f 30 03 0c
0040  43 6f 6e 74 72 6f 6c 20 52 6f 6f 6d 07 08 a1 a2
0050  a3 a4 a5 a6 a7 a8
```

**PENDING** — Sender → Grabber: its user has been asked (34 bytes)

```
0000  56 42 41 4e 60 4e 00 00 45 64 69 74 20 53 75 69
0010  74 65 20 4d 61 63 00 00 00 00 00 00 4e 41 47 53
0020  01 08
```

**DECLINED** — Sender → Grabber: its user said no (34 bytes)

```
0000  56 42 41 4e 60 4e 00 00 45 64 69 74 20 53 75 69
0010  74 65 20 4d 61 63 00 00 00 00 00 00 4e 41 47 53
0020  01 09
```

**OFFER** — Sender → Grabber: accepted; audio follows to this address and port (59 bytes)

```
0000  56 42 41 4e 60 4e 00 00 45 64 69 74 20 53 75 69
0010  74 65 20 4d 61 63 00 00 00 00 00 00 4e 41 47 53
0020  01 05 03 0e 45 64 69 74 20 53 75 69 74 65 20 4d
0030  61 63 04 07 80 bb 00 00 02 00 01
```

**KEEPALIVE** — Grabber → Sender, every 5 s while listening (66 bytes)

```
0000  56 42 41 4e 60 4e 00 00 43 6f 6e 74 72 6f 6c 20
0010  52 6f 6f 6d 00 00 00 00 00 00 00 00 4e 41 47 53
0020  01 06 02 10 21 22 23 24 25 26 27 28 29 2a 2b 2c
0030  2d 2e 2f 30 03 0c 43 6f 6e 74 72 6f 6c 20 52 6f
0040  6f 6d
```

**UNSUBSCRIBE** — Grabber → Sender: stopped listening (52 bytes)

```
0000  56 42 41 4e 60 4e 00 00 43 6f 6e 74 72 6f 6c 20
0010  52 6f 6f 6d 00 00 00 00 00 00 00 00 4e 41 47 53
0020  01 07 02 10 21 22 23 24 25 26 27 28 29 2a 2b 2c
0030  2d 2e 2f 30
```

**AUDIO** — VBAN audio, 2 frames stereo i16 48 kHz: 0.5, −0.5, 0.25, −1.0; counter 7 (36 bytes)

```
0000  56 42 41 4e 03 01 01 01 4d 61 63 20 41 75 64 69
0010  6f 00 00 00 00 00 00 00 07 00 00 00 ff 3f 01 c0
0020  ff 1f 01 80
```

**KNOCK** — Remote link: Sender → the receiving end's code address, to open its router (5 bytes)

```
0000  4e 41 47 4b 01
```

**SEALED** — Remote link (v2): PENDING sealed Sender → Grabber; secrets 01…10 and 11…20, epoch e0…e7, counter 0 (71 bytes)

```
0000  4e 41 47 45 02 e0 e1 e2 e3 e4 e5 e6 e7 00 00 00
0010  00 00 00 00 00 e8 ce 37 b1 f2 66 f9 b7 1e dc 50
0020  9b a7 0c 95 9f a7 c9 e8 5a 08 cc b7 c4 30 87 53
0030  b7 07 35 df 2f 79 bf 71 92 d5 e5 9f 2a 03 c2 cd
0040  2d 14 50 e8 88 51 92
```

**Remote link codes**

- sending end, 203.0.113.30:6981 → `NAG-4B5G0-W8Y3D-2G20G-30G2G-C1R81-450P3-0D1R7-H19R`
- receiving end, 198.51.100.7:6980 → `NAG-47336-S073D-2124G-K2GAH-C5RR3-4D1P7-0X3RF-J1MR`
