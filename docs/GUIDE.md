# Network Audio Grabber

**AES67 / RAVENNA / Dante monitoring for macOS.** Version 0.16.2.

Listen to AES67, RAVENNA and Dante streams on headphones. It finds what senders are advertising
on your network, you pick the ones you want, and they come out of whatever the Mac's current
default output device is.

No virtual audio driver, no PTP daemon, no configuration files.

```
┌──────────────────────────────────────────────────────────────┬─────────────────────┐
│ NETWORK AUDIO GRABBER                                        │ INPUTS     3 joined │
│ ● en5 192.0.2.20 │ 🎧 Headphones 48 kHz   🔍 ACTIVE ⚙︎     │ ● Live Room 1-8 S 8 │
├──────────────────────────────────────────────────────────────┤  ▁▁▁▁▁▁▁▁           │
│  STREAM            TO BUS  LEVEL  TRIM    M/S  SOURCE        │ ● Stagebox-1 TX   2 │
│ ☆ ▶ Dub Stage 7.1                              RAVENNA 8 ch  │  ▁▁                 │
│ ★ ■ Live Room 1-8  Ch 1/2 ▾ ▮▮▯ ──●── +0.0  M S RAVENNA 8 ch ⌄│ ● Studio A 5.1  M 6 │
│ │  ▍▍▍▍▍▍▍▍   SOURCE     FORMAT          GROUP               │  ▁▁▁▁▁▁             │
│ │  L R C LFE  RAVENNA    L24 · 48 kHz    233.252.0.10:5004   ├─────────────────────┤
│ │  SOLO L R C LFE Lss Rss Lrs Rrs  Front Sides Rears         │ INSERTS      440 AU │
│ ☆ ■ Stagebox-1 TX  Ch 1/2 ▾ ▮▯  ──●── +0.0  M S DANTE  2 ch ›│ 1 SoundID  BYP Δ ▤  │
│ ☆ ■ Studio A 5.1   Ch 1/2 ▾ ▮▮▯ ──●── +0.0  M S RAVENNA 6 ch›│ 2 Empty             │
│                                                              │ 3 Empty             │
│                                                              ├─────────────────────┤
│                                                              │ OUTPUT      48 kHz  │
│                                                              │ ▊▊  −4.3 dBFS ●     │
│                                                              │ ▊▊  🔈──────●──     │
│                                                              │ ▊▊  DIM  MONO       │
│                                                              │ L R  Headphones     │
│                                                              ├─────────────────────┤
│                                                              │ LOUDNESS    60 s ⟲  │
├──────────────────────────────────────────────────────────────┤ LUFS-S −21.2 ─●─+1.8│
│                                  3 of 22   Stop all      ☰   │ LUFS-W −23.1 ─●─−0.1│
└──────────────────────────────────────────────────────────────┴─────────────────────┘
```

**One line per stream.** Name, where it goes, its level, its trim, mute and solo, source and
channel count — and the one stream you have open drops its detail in underneath: every channel
metered, the channel solo, and either the stream's own facts or every arrival figure the
receiver keeps, depending on the density. `Settings → View → Stream list` switches between
**Simple** and **Detailed**; Simple is the default and is the shortest path from "there is a
stream on the network" to "I can hear it".

Or the same app in the compact window (⌥⌘C), for leaving on screen next to something else:

```
┌───────────────────────────────┐
│ ● en5  Headphones       ⤢ ⚙︎ │
│ −4.3 dBFS                   ● │
│ L ▁▂▃▄▅▆▇█████▏             │
│ R ▁▂▃▄▅▆▇██████▏            │
│ 🔈─────────────●   DIM  MONO  │
├───────────────────────────────┤
│ LOUDNESS              60 s ⟲  │
│ LUFS-S  −21.2  ──●──    +1.8  │
│ LUFS-W  −23.1  ──●──    −0.1  │
│ LUFS-I  −22.8  ──●──    +0.2  │
├───────────────────────────────┤
│ INSERTS                       │
│ 1 SoundID Reference 100 % BYP │
├───────────────────────────────┤
│ LISTENING                   3 │
│ ■ ● Live Room 1-8      M   S  │
│   ▍▍▍▍▍▍▍  8 ch               │
│ ■ ● Studio A 5.1 Bed   M   S  │
│   ▍▍▍▍▍▍   6 ch               │
│ 3 available  ›                │
├───────────────────────────────┤
│              3 of 6  Stop all │
└───────────────────────────────┘
```


## Build and run

**Both apps need macOS 14.2 (Sonoma) or later.** Command Line Tools are enough to build them —
Xcode is not needed, though its Instruments is what the performance work is measured with.

```sh
./build.sh                          # both apps and the plug-ins; ./build.sh release grabber|sender|au for one
./build.sh release dmg              # the same, then the disk image: build/NAGS-Mac-<version>.dmg
open "build/Network Audio Grabber.app"
open "build/Network Audio Sender.app"
```

**The disk image** holds both apps beside an Applications shortcut, the DAW plug-ins (beta) as
`DAT Audio Plug-ins.component` beside a shortcut to the all-users Components folder, and a Read Me
(`Resources/dmg/Read Me.html`), over a drawn background (`Tools/make_dmg_background.swift`).
It is laid out by [dmgbuild](https://github.com/dmgbuild/dmgbuild) (MIT), fetched once into
`.build/dmg-venv`; a build tool only, nothing of it ships.

**About and Licences.** Each app's About window (app menu) shows the version and the credits
scrolling slowly underneath — what the apps work with and who made it, what they are built with,
the one outside service, the trademarks — pausing under the pointer and standing still with
Reduce motion on. **Licences…** shows every licence the app carries, in full. The credits text is
`Sources/NetworkAudioShared/Credits.swift`, also shown by Settings → Credits.

### A stable signature for development

`build.sh` signs ad-hoc unless this Mac has a code-signing identity called **Network Audio Local
Signing**. The difference matters for the Sender: macOS ties the System Audio Recording
permission to the app's signature, and an ad-hoc signature changes with every build, so after
each rebuild the Sender captures nothing while System Settings still lists it as allowed. A
self-signed certificate keeps the signature stable. Once per Mac:

```sh
cat > /tmp/nals.cnf <<'CNF'
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = Network Audio Local Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/nals.key -out /tmp/nals.pem -days 3650 -config /tmp/nals.cnf
openssl pkcs12 -export -legacy -inkey /tmp/nals.key -in /tmp/nals.pem -name "Network Audio Local Signing" -out /tmp/nals.p12 -passout pass:temp
security import /tmp/nals.p12 -k ~/Library/Keychains/login.keychain-db -P temp -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db /tmp/nals.pem   # asks for your password
rm /tmp/nals.*
```

Allow the Sender once more after the first signed build; after that the permission survives
rebuilds. `SIGN_IDENTITY=- ./build.sh` forces ad-hoc.

> **Upgrading from 0.4 (when this was called something else):** the app was renamed, and the
> bundle identifier changed with it — so macOS treats this as a new app and **Local Network
> access must be granted again**. Until it is, RAVENNA and Dante discovery silently return
> nothing while SAP keeps working, which looks exactly like a fault in the app rather than a
> permission. Settings themselves are carried over automatically.

On first launch macOS asks for **Local Network** access. **Allow it.** If it is denied or the
prompt is missed, RAVENNA and Dante discovery silently return nothing while SAP keeps working,
which looks like a fault in the app rather than a permission. Grant it in System Settings →
Privacy & Security → Local Network. The app logs a reminder if Bonjour stays empty for 20 s.

## Using it

1. **Pick the interface** (top left) that is on the audio network. This matters — on a Mac
   with more than one NIC, joining a multicast group on the wrong one receives nothing.
   Streams may still be *discovered* on the wrong interface, because Bonjour crosses
   interfaces, while no audio arrives; the log says so when that happens.

   The menu lists **every** multicast-capable interface with an IPv4 address, **Wi-Fi included**,
   and marks which is which. Wired NICs are listed first and one of them is the default, because
   that is nearly always where the audio network is. Wi-Fi works, with real caveats — see below.
2. **Press ▶ on a stream** to join its multicast group and start playing. Several streams can
   play at once; they are summed.
3. Every active row carries **M** (mute), **S** (solo) and a trim control. Clicking the row adds the
   diagnostic figures — buffer, drift, loss, underruns.
4. Use the **filter** box and the **ACTIVE** toggle to keep a long list manageable, and ★ to
   pin the streams you use most to the top.

Output follows the Mac's default output device live — change it in Control Centre and the app
moves with it — **unless you choose a device**: click the device name in the header, or
Settings → Output → Device. A chosen device stays chosen whatever the Mac's own setting does; if
it is unplugged, the Grabber plays on the default until it is back, and says so. For several
devices at once, make a Multi-Output Device in Audio MIDI Setup and choose that; to feed another
app, choose a virtual device such as BlackHole and use it as that app's input. Streams you were listening to are rejoined next time they are announced.

**Nothing stops by itself.** A stream you play stays joined until you stop it, however long it
is quiet — hours or days — and plays again the moment it comes back; streams playing when the app
quits are joined again when it next opens and finds them. To have quiet streams stop instead,
turn on **Settings → Playout → Auto-stop** and pick how long (1 minute to 24 hours). Each playing
stream is timed on its own; one that is stopped says **Timed out** on its row — hover for when,
and which setting did it — and stays listed until you play it again.

### Send, from the Grabber

The Grabber can also **send this Mac's audio** to other receivers — another Grabber, Voicemeeter,
any VBAN receiver — with Network Audio Sender's own controls, so there is no need to run both
apps. It sits in three places:

- **A Send section along the bottom of the full window**, open by default: this Mac on the left
  (stream name, meter, format), the receivers on the right. Drag the handle above it to make it
  taller or shorter (up to about 40% of the column); the chevron folds it to one line.
- **Connect / Send…** on the list bar opens a **Receive / Send** window beside the main one. Each
  tab starts by saying which way the audio goes: *Receive* is the guide for connecting to a
  Network Audio Sender on another Mac; *Send* is the same Send controls. Help → Send This Mac's
  Audio… opens it too.
- **A Send tab in the compact window**, beside Receive.

**MUTE ALL** sends silence to every receiver and keeps them all connected; **Stop sending** stops
everything, including Findable by Grabbers. While anything is sent, a **● Sending · N** pill sits
in the status bar (and the compact footer; on the compact Send tab it becomes **● Receiving · N**
for what is playing); click it to get to the controls. Green while audio goes out, amber when the
Mac is silent or macOS is delivering nothing.

Send has **its own settings** (Settings → Send): stream name, 16- or 24-bit, channels, "Resume
sending when opened" and its own auto-stop — separate from the Sender app's, so both can run on
one Mac. What this Grabber plays is never sent, and its own Send is left out of its stream list.
**It costs nothing until used**: no port, thread or timer runs until something is sent or offered,
and it all stops again after. The first time it sends, macOS asks to let the Grabber record this
Mac's audio.

### The two windows

**⌥⌘C** switches between the full window and a compact one, and back. The compact window is the
same app in a narrower arrangement — the monitor controls, the loudness readings, the inserts and
whatever is playing, with the discovery list folded behind a disclosure. Every control drives
exactly what its equivalent in the full window drives: the interface, the output bus, the insert
slots and their plugins, each stream's mix mode and channel order. Each window remembers its own
size, so switching does not flatten the other one.

Every **slider resets to its default on a double-click**: the monitor level to unity, a stream's
trim to 0 dB, an insert's dry/wet to fully wet, the buffer to 15 ms (VBAN's to 20 ms).

Its sections **fold**. `LOUDNESS`, `INSERTS` and `LISTENING` each have a disclosure and each
remembers whether you left it open, so the window is as small as the thing you are actually
watching — everything folded is about 300 points, everything open about 560, and it resizes
itself as you fold. A folded section keeps a summary on its header rather than disappearing: what
is playing, what is loaded, and all three loudness figures across one row. The monitor strip does
not fold; it is what the window is for.

It goes down to **330 points wide** — what the folded loudness row needs to hold all three
figures — and remembers whatever width you leave it at. As it narrows,
rows shed the least valuable part rather than wrapping — the peak row drops its `dBFS max` label
before it drops the pinned loudness figure, and the folded loudness summary drops from three
readings to two to one. A **loudness reading is pinned beside the peak figure** at nearly the
same size, chosen in `Settings → Loudness → Pinned loudness` and integrated by default, so the number
you judge by is readable from across a room; that choice is offered only while loudness readings
are switched on. The header also says how many outputs the device
has, and the bus menu reads `2 of 16 ch`.

What the compact window leaves out, deliberately, is **information rather than control**: the
per-channel input meters and the per-stream diagnostic figures, neither of which is readable at
330 points, and the search box, the manual-SDP sheet and the log pane. Appearance and everything
else lives in Settings, which opens in either window.

There is also a **Window** picker in Settings → View, and buttons on both layouts.

### Multichannel output

The monitor bus is **stereo by default** and can be as wide as the output device allows. The
menu beside the output meters — also `Settings → Output → Output bus` — offers stereo, the SMPTE
layouts the device can carry, and its full width:

```
Output bus ⌄
  Stereo (fold down)     ← default
  4.0
  5.1
  7.1
  16 ch
```

**The choice is remembered per device**, so a monitor rig keeps its 7.1 and headphones keep
their stereo without either overriding the other. A remembered width that the current device
cannot carry falls back to stereo and says so in the log.

On a wide bus, a stream that fits plays out **channel for channel** (`7.1 direct`) and fold-down
stops applying to it. A stream narrower than the bus leaves the rest of it silent; a stream wider
than the bus folds to stereo on channels 1–2. Loudness follows BS.1770 across the bus — surrounds
+1.5 dB, LFE excluded — and the master meters draw every channel.

Stereo remains the default deliberately: folding reaches whatever you are listening on, whereas
matching the device reaches only what is wired to your ears. On a wide interface a 7.1 bed puts
the centre channel on output 3, which is silence if you are on headphones in outputs 1–2.

### Settings

**⌘,** or the gear opens Settings **in the window**, not in one of its own: it takes over the
stream list, so the signal panel, the master meters and the status bar stay where they are and
the buffer can be tuned while watching what it does. The same seven sections — Playout,
Fold-down, Discovery, Output, Loudness, Theme, View — are picked from a sidebar, or from a row of
icons in the compact window. **Done**, the gear again, or ⌘, goes back.

Each section explains itself where it needs to, but the long explanations sit behind a
**ⓘ disclosure** rather than under the controls, so a pane is the settings first and the reasoning
second.

### The source sidebar

Down the left of the full window: **All streams**, or one kind — RAVENNA, Dante, AES67 (SAP),
VBAN, Scream, internet radio, manual — each with its count. A kind appears once a stream of it
has been found. The choice is remembered; the `sidebar.left` button in the header hides the
sidebar. The compact window has the same filter as small toggles above its Listening list.

### The signal panel

The right-hand panel is the monitor path, top to bottom in the order the audio travels:

- **Inserts** — three Audio Unit slots, with the chain's added latency beside the count of
  plugins available. Folded to start with; folded, it lists what is loaded.
- **Output** — the peak maximum (with its clip dot) and the loudness readings on the left, the
  master meters on the right with a dB scale and channel names, as tall as the window allows.
  The pinned loudness reading comes first and larger. Under them: master level, DIM, MONO and
  the last 30 seconds of level history.

Every channel of every playing stream is in its row's Level column, one hairline each, so the
streams you are *not* looking at stay visible — losing sight of them is how a silent or
misrouted channel goes unnoticed. Several rows can be open at once to compare streams. A muted
stream's meters have a dark red surround; a stream silenced by another's solo is grey.

Toggle the panel from the toolbar. Meters refresh at 20 fps with a 200 ms fall time; they stop
entirely when nothing is being listened to, which keeps idle CPU at zero.

### Soloing individual channels

Click a row and every channel of that stream appears as a chip — SMPTE names when
the channel count matches a known layout, numbers otherwise. Click any of them to monitor just
those channels. For the surround layouts there are one-click groups: **Front**, **Sides**,
**Rears**.

Soloed channels are heard **in the positions the fold-down gives them**, so soloing `Lrs` and
`Rrs` on a 7.1 stream is the rear pair, left and right, at the level they sit at inside the full
fold-down. The trim stays applied, which means a solo is *level-matched*: if only the rears carry
signal, soloing them reads the same LUFS as the whole fold-down does. That is what makes it
usable for A/B rather than just for listening.

> **A channel solo overrides the mix mode while it is engaged.** It does not filter it. Filtering
> would have meant that soloing channel 7 on a row set to `Ch 1/2` produced silence, because
> channel 7 is not in that matrix. A solo always makes a sound.
>
> A single soloed channel is heard in its own position, which for a rear channel means one ear.
> **`Ch N mono`** in the mix menu is the way to hear one channel centred — the two controls
> answer different questions.

The row follows along: soloed channels stay lit and named in the secondary colour, everything
else dims, and the row carries an outlined `S Lrs Rrs` badge beside the stream's name.
Nothing about it is persisted between launches — like stream solo, it is something you
do while listening.

`--selftest --solo 7,8 --mixmode downmix` drives it headlessly.

### Multichannel output

**The monitor bus is stereo, whatever the output device is.** Connecting a 5.1 or 7.1 interface
does not give you 5.1 or 7.1 out; you get the stereo monitor mix on channels 1–2 and silence on
the rest. Measured by rendering a stereo chain into wider layouts:

| Output layout | Channel peaks |
| --- | --- |
| Stereo | `0.500  0.250` |
| 5.1 | `0.500  0.250  0  0  0  0` |
| 7.1 | `0.500  0.250  0  0  0  0  0  0` |

So nothing is duplicated or spuriously upmixed — it is clean, just stereo. To hear a surround bed
you fold it down, pick a pair, or solo the channels you want (see **Soloing individual
channels**), all of which is what this app is for: checking what is on a bus through headphones.

**Native surround output is a planned expansion**, not a closed door. It is a real piece of work
rather than a flag, because the stereo assumption runs the whole length of the signal path — the
engine format, the per-stream mix matrix, the insert chain, the meters and the BS.1770 channel
weighting all assume two channels. The scope, the open design question (surround pass-through
versus arbitrary routing) and the part most likely to derail it (stereo-only insert plugins) are
planned for a later version.

### Loudness

Peak metering answers "how hot is what I am hearing". The loudness block answers "how loud is
this material", which is a different question, so it is measured at a different point — see
below. Three readings, to **ITU-R BS.1770-4** / EBU R 128:

| Reading | Window | Gated |
| --- | --- | --- |
| `LUFS-S` | 3 s, fixed | no |
| `LUFS-W` | whatever you set, 1 s to 10 minutes | yes |
| `LUFS-I` | everything since the last reset | yes |

Each has its own **target**, and each shows how far it sits from that target both as a figure in
LU and as a dot on a centre-zero bar, so the common case — is this on target — needs no
arithmetic. Green inside 1 LU, amber inside 3, orange beyond. Settings → Loudness sets the
window length, the three targets, and has one-click presets for **−23 LUFS** (EBU R 128
delivery) and **−14 LUFS** (the streaming platforms).

**⇧⌘L** resets the integrated and window readings, as does the ⟲ button on the block. The
shortcut works while Network Audio Grabber is the active app; a system-wide one is noted as outstanding.

`LUFS-I` is greyed until about three seconds of gating blocks have gone by, because an
integrated figure swings wildly before that and means nothing.

> **Where it is measured.** On the summed bus, **before master level, DIM, MONO and the
> inserts.** Pulling the monitor level down must not drop `LUFS-I` with it, and room correction
> in an insert is not part of the programme. The peak meters stay where they were, post-insert
> and post-monitor-level, because they should show what actually reaches the headphones.
>
> `NetworkAudioGrabber --selftest --silent --iface <nic> --only <stream>` demonstrates it: master at zero,
> nothing out of the audio device, readings unaffected.

Gating, the K-weighting and the 400 ms blocks are all as specified. Coefficients are derived at
the output device's actual rate rather than copied from the spec's 48 kHz table, so the weighting
is still right on a 44.1 or 96 kHz device. `Tools/lufs_test.swift` checks the whole thing against
closed-form answers.

### Channel handling and SMPTE order

The mix menu on each active row chooses how that stream folds into the stereo monitor bus:

- **Ch 1/2, Ch 3/4, …** — a straight pair, the default.
- **Single channel** — one channel to both ears.
- **Fold 5.1 → 2.0 / 7.1 → 2.0** — a proper downmix, offered on 4-, 6- and 8-channel streams.

> **Channel order is always assumed to be SMPTE.** AES67 and Dante carry no channel-order
> metadata whatsoever, so a fold-down has to assume something, and this app assumes:
>
> | | Order |
> | --- | --- |
> | 4.0 | L R Ls Rs |
> | 5.1 | L R C LFE Ls Rs |
> | 7.1 | L R C LFE Lss Rss Lrs Rrs |
>
> That is SMPTE ST 2036-2 ordering, **not** the ITU "L C R Ls Rs LFE" variant. If a sender
> uses a different order, pick channel pairs by hand instead.

Fold-down coefficients follow ITU-R BS.775: centre −3 dB, side surrounds −3 dB, rear
surrounds −6 dB, LFE excluded. LFE can be folded in at −10 dB from Settings. Because
`L + 0.71·C + 0.71·Ls` can reach +7.6 dB, a **downmix trim** is applied (0 / −3 / −6 dB,
default −3 dB) — Settings → Fold-down.

### Channel order

Multichannel streams are read in **SMPTE** order — 5.1 as `L R C LFE Ls Rs`, 7.1 as
`L R C LFE Lss Rss Lrs Rrs` — and that is the default. **Nothing in an AES67 or Dante stream
declares its channel order**, so this is an assumption, not a detection, which is why it can be
changed: `Settings → Fold-down → Channel order` offers `ITU/DTS — L R Ls Rs C LFE` as well, and
a single stream can be set differently from its own menu in the list. The order belongs to the
sender, so two devices on one network can disagree and each be right.

The order decides four things: the fold-down gains, the channel labels under the meters, which
channel is excluded as LFE, and which channels carry the +1.5 dB loudness weighting. On a wide
bus it also decides the mapping — the bus is always SMPTE-ordered, so a stream declared ITU has
its surrounds sent to the bus positions where surrounds belong rather than to the channel
numbers they arrived on.

Fold-down is automatic for quad, 5.1 and 7.1 streams, and **each stream remembers what you last
set it to**. Nothing in an AES67 SDP distinguishes a 7.1 bed from eight discrete feeds, so the
automatic choice is a guess either way; it is made in favour of folding because monitoring on
headphones usually means wanting the whole bed, and because a wrong guess is corrected once per
stream rather than every session. Put a discrete feed back on `Ch 1/2` from its own menu and it
stays there. Settings → Fold-down turns the automatic part off entirely.

### Dante

Turn on **Settings → Discovery → Dante devices**. The app then finds Dante gear over
Audinate's Bonjour services and tags its streams `DANTE` in the list.

What it can receive is **Dante in AES67 mode**. A Dante device with AES67 enabled transmits
ordinary L24/48 kHz multicast RTP and announces it over SAP, which this app already listens
for. Native Dante flows use a proprietary transport that needs Audinate's licensed SDK and
cannot be received here.

So, in Dante Controller: enable **AES67 mode** on the device (Device View → AES67 Config,
then reboot), then create a multicast flow with **"AES67 flow" ticked** before choosing
channels. Flows are multicast only and hold at most 8 channels each, and can take up to 30 s to
be announced. Settings marks every discovered Dante device `AES67` or `no flow`.

A Dante AES67 flow is announced as `<device> : <flow-id>` — for example `Studio-Rack : 32`. If a
device is listed but no `<device> : NN` session appears, it is publishing nothing.

**Dante Virtual Soundcard and Dante Via cannot do AES67 at all**, whatever you route into them.
AES67 needs Dante hardware on a Brooklyn, Broadway or HC chipset with firmware 4.2.x or later.
To hear a DVS source, either subscribe its channels to a hardware Dante device and create the
AES67 flow there, or use a RAVENNA driver on that machine instead.

### VBAN

VB-Audio's protocol — Voicemeeter on Windows, VBAN apps on phones. **On by default** (since
0.15, so a Network Audio Sender made Findable shows up with nothing to switch on; turn it off in
**Settings → Discovery → VBAN**): the app listens on UDP 6980 and lists any VBAN stream sent
to this Mac, tagged `VBAN`. It listens on every network this Mac is on, whichever one the
Grabber's AES67 interface is set to: a broadcast on another of its networks is heard too. VBAN has no discovery of its own, so the *sender* is pointed at the
receiver. With VBAN on, **Settings → Discovery → Send VBAN to this Mac** lists every address
this Mac has — wired, Wi-Fi and VPN, each with a copy button, and each network's broadcast
address — and the port. A broadcast address reaches every Grabber on that network at once,
but also floods every other device on it, so prefer this Mac's own address for one receiver. In Voicemeeter's
VBAN window, switch an outgoing stream on and set its IP address to the one on the sender's
network (or that network's broadcast address, e.g. `192.0.2.255`), port 6980, PCM. The stream name there is the name in the list. A stream appears while its packets
arrive and leaves 15 s after they stop; one that changes format mid-stream is rejoined
automatically.

**A Network Audio Sender needs none of that.** **Connect to a Sender over VBAN…**, beside the
list's STREAM title, walks through it. One that is offering its stream (see below) appears in
the list by itself; press play and it sends to this Mac only, and stops when you
stop. The Grabber tells it its name — **Settings → Discovery → Network Audio Sender → This
Grabber's name**, the Mac's own name by default — and the Sender shows it. Where the offer cannot
reach, such as over a VPN, add the Sender there by address (port 6981); it then sends here for as
long as it is listed.

It is unauthenticated: anything that can reach this Mac can send to it. Nothing is decoded
until you join a stream, and at most 32 VBAN streams are listed — 8 from any one sender, 4 new
ones a second — so a flood of made-up streams cannot swamp the list or lock real senders out.
The listener accepts on every interface, a VPN included, which is what makes it the one receive
path that works remotely (see **Remote access** below).

### Another location

**Connect / Send…** asks first **where the other end is**: *On this network* (the steps as
before) or *Somewhere else* — another building, home and work, across the internet. It is the
place to set up any connection the app cannot find by itself.

Somewhere else offers three ways, each a radio header with one plain sentence; only the chosen
one opens (the Remote link unless another was chosen, and remembered):
- **Remote link (recommended)** — between our apps: a Grabber at one place, a Network Audio
  Sender (or a Grabber's Send) at the other. Each end presses **Make this end's code** and sends
  the code to the other by message or email; each pastes the other's and presses **Connect**.
  **Nothing to open on either router**: both ends reach out, and the sending end lets in only the
  Grabber whose code it was given — no asking. The stream is VBAN underneath, **encrypted end to
  end** (ChaCha20-Poly1305) with keys only the two ends have, marked REMOTE · ENCRYPTED. **Several links at once**: one end's code does for every other end,
  and each link lets in exactly the address and port its code gave — not every device behind
  that router. Links are listed, with **Unlink**. A code is good for about 15 minutes after it is
  made; a link is kept, and picked up again when the apps reopen. It needs routers that keep one outside port
  per Mac (most home and office routers do); where it cannot connect, By address is the fallback.
- **Or: a VPN** such as Tailscale on both Macs. The other place becomes part of the network —
  encrypted, nothing to open on a router — so choose *On this network* and add the other Mac by
  its VPN address if it is not found.
- **By address** — for other VBAN senders and receivers (**not advised over the internet**): a Network Audio Sender, a Grabber
  or any VBAN device reached at its network's outside address. The receiving end's router has
  to forward a port to it (UDP 6980, or 6981 for a Sender's offer), which lets anyone on the
  internet send to it, and the audio crosses the internet unencrypted — fine over a VPN or for a
  short test. The guide says so first; so does every address field, as soon as the address typed
  is outside this Mac's networks, and the button then reads **Add anyway**.
- **Find this network's outside address** asks Cloudflare's public STUN server what this
  network's address is on the internet, for the other end to type in. Only when pressed; nothing
  else is sent.

Anything coming from, or going to, another location carries a **REMOTE** badge on its row, in
words as well as a padlock: **REMOTE · ENCRYPTED** for a Remote link, **REMOTE · NOT ENCRYPTED**
(open padlock) for anything added by address. VBAN on this network says **LOCAL** — also not encrypted, which is fine on a network you trust
(the tooltip says so). Over a VPN such as Tailscale (a 100.64.x address) it says **VPN**, and
plays on the remote buffer, since it crosses the internet all the same.

A Remote link works whether or not **Findable by Grabbers** is on, so linking never announces
the stream on the local network. **Stop sending** pauses the links too; the card says so and
has **Resume**.

**Remote streams' buffer.** Streams marked REMOTE cross the internet, where packets arrive less
evenly, so they have a buffer of their own in Settings → Playout (60 ms to start). **Test the
connection** listens to a playing remote stream for 30 seconds and suggests a figure; press
**Use** to take it, or set the slider yourself. Nothing changes it otherwise.

Remote link codes from builds before 0.15 (unencrypted) are refused; make new ones at both ends.

### Inserts (Audio Units)

Three insert slots sit between the summed streams and the output — room correction, an EQ,
whatever is installed. Each slot has a plugin menu (grouped by manufacturer), a **BYP** bypass
and a button that opens the plugin's own window. The choice and the plugin's own settings are
restored on the next launch.

Each slot is wired as a parallel pair rather than in line:

```
upstream ─┬─ plugin ─ wetGain ─┬─ sum ─→
          └────────── dryGain ─┘
```

so **BYP** is a hard bypass — the wet path is silenced and the dry path carries the signal at
unity — rather than a request to the plugin. `shouldBypassEffect` is a request, and plenty of
Audio Units ignore it. The same two gains give a **dry/wet balance** anywhere in between, the way
Reaper does it per-FX, and they give it for *every* plugin — including the many EQs and
room-correction plugins that have no mix control of their own, because the balance is ours and
not theirs. Neither stops the engine; only loading or clearing a plugin rebuilds the chain.

**Δ is delta monitoring** — Reaper's delta solo. Instead of the processed signal you hear the
*difference* the plugin is making, `wet − dry`, which is the quickest way to tell whether a
plugin is doing anything and what. It is a comparison at unity, so it overrides the dry/wet
balance while it is lit and hands it back afterwards, and only one insert can be in delta at a
time. The dry leg is delayed by the latency the plugin reports so the subtraction nulls instead
of comb-filtering; where a plugin reports none, the log says so, because then nothing is being
compensated and a plugin that under-reports will leave a difference it never made.

> Delta shows on the **master meters**, which sit at the end of the chain. It cannot move the
> loudness readings — those are measured on the summed bus before the inserts.

> The dry path is **delayed to match** whatever latency the plugin reports, so a partial blend
> sums instead of comb-filtering, and an A/B at any position on the knob is like for like. The
> log names the figure the first time you blend a latent plugin. A plugin that under-reports its
> latency will still comb, and BYP is the only path with no insert latency in it at all.

The dry/wet slider is **hidden by default** — it is the widest control in an insert row and the
least reached for, and Δ answers what it is usually opened for. Turn it on in
**Settings → View → Show dry/wet on inserts**; hiding it changes no balance already set.

macOS loads **Audio Units**. VST/VST3 would need Steinberg's host SDK bundled in, but
essentially every room-correction and EQ plugin ships an AU alongside its VST, so the
practical coverage is the same.

### Colour scheme

**Settings → Theme** tints the window on top of light/dark. Both apps start on **Graphite &
Amber**; **System colour scheme**, the first choice in the picker, leaves the system's own
colours alone. Two colours, doing two different jobs:

- **Window** washes every surface. An ultramarine theme means a lightened-ultramarine window
  with the signal panel sitting a shade apart, instead of white with off-white panels.
- **Active** is anything you have switched on: a stream you are listening to and its stop
  button, `ACTIVE`, the signal-panel toggle, MONO, the sliders.

Presets — Ultramarine & Canary, Teal & Coral, Plum & Gold, Slate & Lime, Graphite & Amber — plus
a colour picker for each. Changing a colour makes it a custom scheme.

The window colour is applied as a **wash over the appearance's own background**, not as a flat
fill. That is what keeps the shading: every surface in the app is built from
`Color.primary` at a low opacity, so each one still darkens in light mode and lightens in dark
mode exactly as before — just over a tinted ground rather than a neutral one. Light and dark
still decide the shading; the theme tints it.

What it deliberately leaves alone is everything whose colour is *information* rather than
decoration:

| Fixed | Why |
| --- | --- |
| Meter green / amber / red | The colour **is** the level — green to −18 dBFS, amber to −6, red above. |
| RAVENNA blue, Dante green, SAP violet | They identify which transport a stream arrived on. |
| Solo yellow | Solo is yellow in every DAW there is, and it has to stay distinct from **Active**, which is themeable. |
| Mute red, clip red | Danger, and conventionally red. |

Two things keep an arbitrary colour usable. Text on a coloured pill flips between black and
white by luminance, so a canary-yellow chip is legible rather than white-on-yellow. And where
the Active colour is drawn as a glyph rather than as a low-opacity fill — the stop button, for
instance — it is nudged towards gold in light mode and away from near-black in dark mode, enough
to be seen without losing the hue.

**Rea-Theme Default brings REAPER's look as well as its colours:** square mint meters in a dark
well, fader caps in dark grooves instead of slider fills, near-square buttons, a green play-stop
button (black at rest) and REAPER's meter scale between the master's bars. The other schemes keep
the app's own look. (Built as a *skin*, so other looks can be added later.)

**More schemes with their own look**, listed after it: *Lojick* (in the style of Logic Pro),
*Abletron* (Ableton Live), *Wise* (Wwise), *FNod* (FMOD Studio), *MidTools* (Pro Tools),
*Bitlick* (Bitwig Studio), *RogueSingleCell* (Audio Hijack) and *AudaTown* (Audacity). Each sets
its own window, panels, meters, faders, buttons and play button, and is always light or dark:
while one is chosen, Appearance is greyed out. The names are affectionate nods; none of these
apps' makers is involved.

### Reading the meters at a glance

**A coloured bar is reaching the output. A grey bar is not.** One rule, and three states land on
it — a muted stream, a stream silenced by another stream's solo, and the channels outside a
channel solo. Grey is a flat fill rather than a dimmed gradient, because a channel outside a solo
is not turned down, it is out of circuit.

Alongside it, the signal panel marks state in filled blocks rather than coloured letters: `M` in
red for muted, `S` for soloed, and the fold-down caption blocked in the solo colour while a
channel solo is engaged — `Solo Lrs Rrs`. The soloed channels' own labels are blocked too, so the
panel says which channels you are on without needing the row open.

**`M` means you muted that stream, and nothing else.** The streams a solo silences are not
badged: their bars going grey says it, the `S` says where the solo is, and the status bar carries
a `SOLO` flag with a Clear button. Channel names switch to SMPTE (`Lrs`, `Rrs`) whenever a
channel solo is engaged, so the caption, the bar labels and the row's chips all agree — a channel
solo is defined in SMPTE positions, so naming them numerically was the odd one out.

### What mute and solo actually do

Measured rather than assumed, with one stream playing:

| | Muted | Soloed elsewhere |
| --- | --- | --- |
| Output, and the output meters | silent | silent |
| **Loudness readings** | **drop out** | **drop out** |
| That stream's input channel meters | keep running | keep running |
| That row's level bar | keeps running | keeps running |

So a muted stream leaves the monitor sum entirely, and because loudness is measured on that sum
it leaves the LUFS reading too — mute one of two streams and the figures describe the one that is
left. The input metering is upstream of all of it and carries on, so a muted source is still
visible.

That is a deliberate reading of mute as a *programme* decision rather than a monitoring one: the
master level, DIM and MONO are excluded from the loudness measurement because they change
how loudly you are listening, whereas muting a stream changes what the programme *is*. It is also
what makes the most useful version of this work — **solo a stem and read its LUFS** — possible at
all, since solo reaches the measurement by the same route.

**Muting everything does not destroy a running measurement.** Silence sits below BS.1770's
−70 LUFS absolute gate, so those blocks never enter the integrated reading and it simply *freezes*
where it was. Measured: muting the only stream 18 s into a run left `LUFS-I` at −21.1, and it was
still −21.1 after a further 18 s of silence. `LUFS-S` collapses to −∞ immediately, being ungated
by definition, and `LUFS-W` holds until silence fills its window.

**Muting one of several streams is the case to watch.** That is not silence — the remaining
streams are above the gate, so those blocks *do* go into the integrated reading, and it ends up
describing a mixture of "with" and "without". If you mute something mid-measurement and the
integrated figure matters, reset it (⇧⌘L, or double-click the block).

### Monitor controls

- **DIM** — −20 dB, the usual monitor-controller amount.
- **MONO** — sums to mono for a quick phase check.
- **S** on a row — everything else mutes.
- **The figure beside the master meters is a maximum, not a live level** — the highest output
  level since it was last reset, labelled `dBFS max`. The bars show the level continuously, so
  the number is better spent on "how hot did this get"; and because a maximum only changes when a
  new peak beats the old one, it needs no redrawing at all, which is what keeps it cheap.
  **Double-click it** to start logging a new maximum; the clip dot resets it too.
- **Double-click the loudness block** to reset the integrated and window readings — the same as
  the ⟲ button and ⇧⌘L, for when your eye is already on the figures.
- The monitor level shows its **position as a percentage** beside the slider. It is a linear
  amplitude control, so 50 % is −6 dB rather than half as loud; the decibel figure is in the
  tooltip.
- The master meter is post-insert, with peak hold and a clip dot; click the dot to reset it.
- Meter colours follow level, not bar position: green to −18 dBFS, amber to −6, red above.
- The master bars run at 60 fps and their fall is computed from elapsed time rather than stepped
  per callback, so it slides instead of stair-stepping. Input and row meters stay at
  20 fps, where the extra frames are not worth the draws.
- **The output displays release at different rates**, because they answer
  different questions. The **bars** are a one-pole follower with a 25 ms attack and a 0.30 s
  release — the metering tap only fires at 10 Hz whatever buffer size is requested, so a bar with
  instant attack and a fast fall sawtoothed between callbacks; a short attack turns each
  measurement into a rise instead. The **dBFS figure** and the **peak hold** keep instant attack,
  so the true peak is still reported: the figure falls at about 17 dB/s, and the hold sits where
  it was hit for 1.5 s before sliding down at about 7 dB/s.
- **The meters are drawn by AppKit, not SwiftUI**, and refresh at **30 fps** by default
  (**Settings → View → Meter refresh**, 20/30/60). This is the app's largest cost by a wide
  margin — 60 fps measures about 15 % of a core against 8–10 % at 30 — because every redraw makes
  the window compose a frame. 30 is where the curve flattens while the bars still read as
  continuous. The loudness figures are fixed at 10 fps, which is the rate the loudness meter
  produces them at.
- **Settings → Output → Headphone safety limiter** puts Apple's peak limiter last in the
  chain. Off by default.

### Sample rate

AES67 is 48 kHz. If the output device runs at another rate the app resamples and shows the
rate in orange. `Settings → Output → Sample rate` lists the rates the device reports it can run
at, so a device can be put on 48 kHz to keep conversion out of the path — and put back
afterwards. This is the device's own nominal rate, not an app preference: every application using
it sees the change, which is why the setting names rates rather than offering one right answer.

### Wi-Fi

Wi-Fi is listed alongside the wired NICs and can be selected like any other. It is worth knowing
what is different about it before relying on it, because the failure modes look like faults in
this app:

- **The Wi-Fi network is usually a different subnet from the audio VLAN, and multicast does not
  route between subnets** without the network being set up for it. This is the first thing to
  check and it is nothing to do with Wi-Fi being wireless: if the audio VLAN is `192.0.2.x` and
  Wi-Fi hands out `198.51.100.x`, the streams will be *discovered* — Bonjour crosses interfaces —
  and deliver no RTP at all. Measured exactly that in testing: the same stream gave
  24,780 packets on the wired NIC and **zero** over Wi-Fi, and the app's own "no packets" warning
  fired.
- **Even on the right subnet, an access point is not a switch.** It may not forward multicast at
  all, may rate-limit it to the slowest associated client, or may flood it to every client on the
  SSID.
- **Arrival jitter is much higher.** A wired 1 ms stream on this network already needed ~12 ms of
  buffer headroom (see **Latency**); Wi-Fi should be expected to need considerably more. Raise the
  buffer until `underruns` stops moving, and use the `jitter` figure rather than guesswork.
- **It shares the air with everything else.** Contention, roaming between access points and
  power-save behaviour all show up as gaps.

Selecting a Wi-Fi interface logs a note saying as much, once, so it is not a surprise later. For
anything you are judging rather than just checking, use the wire.

### Latency

**The buffer setting is a total, and the output device's own buffer is spent first.** That is
worth knowing before tuning anything, because it is usually where the latency has gone:

```
buffer setting  ─┬─ output device buffer   (512 frames = 10.7 ms by default)
                 ├─ two packets of slack   (2 ms at 1 ms ptime)
                 └─ what is left           ← the only part that absorbs network jitter
```

A device sitting at 512 frames leaves just **2.3 ms** of a 15 ms setting doing any jitter
absorbing. Dropping it to 128 frames leaves 10.3 ms, and on a live 1 ms stream that took
underruns from 28 per 45 s to zero *at the same setting*. **Settings → Playout** sets the device buffer and shows the whole budget live, along with
the measured arrival jitter, the lowest the buffer got and the clock drift.

So: set the device buffer as low as it will go cleanly (128 frames is usually safe, 64 on good
hardware), then lower the app's buffer until `underruns` starts moving and back off a notch. A
stream's figures show the underrun count and when the last one happened.

**VBAN has its own buffer**, shown under the AES67 one while VBAN is on, and 20 ms by default.
VBAN usually comes over Wi-Fi or a VPN, where packets bunch up far more than on a switch: in
testing, 18–22 ms over Wi-Fi ran clean for minutes, and 16 ms started to underrun.

**If a stream needs a lot of buffer, measure before blaming the network.** The figures behind a
row's disclosure separate the causes:

| Figure | What a bad number means |
| --- | --- |
| `lost` | The network is dropping packets. Switch, VLAN or IGMP. |
| `drift` | Clock offset between the sender's PTP domain and this Mac. Tens of ppm is normal and handled; hundreds sustained is not. |
| `jitter` / worst | Packets arriving unevenly. The buffer has to cover the *worst* figure. A large number is the sender's packet pacing or the switch — not this Mac. |
| `underruns` | The buffer ran dry. Compare against the jitter figure before raising it. |

A PC-based sender bursting its packets will show a large worst-case jitter with zero loss, and
**every** receiver on that stream needs the same buffer to cover it — a hardware receiver included.
That is a sender-side problem and no amount of buffer setting here fixes the cause.

The Mac's audio clock is not locked to the sender's grandmaster, so the app resamples by a
fraction of a percent to hold the buffer level steady — `drift` is how much, in ppm.

Measured against real RAVENNA hardware this sits in the tens of ppm and is inaudible. This is
monitoring, not a PTP-locked device: right for checking what is on a bus, not for recording
against timecode.

## The Audio Units

**To install them: Help → Install DAW Plug-ins (beta)… in the Grabber**, which carries them and
copies them into your own Components folder — no password, no Terminal; the same item updates or
removes them later. The disk image also offers them, for all users of a Mac. From source,
`./build.sh release au install` builds `Network Audio Grabber.component` and copies it into
`~/Library/Audio/Plug-Ins/Components`. It holds three plugins, from the maker **DAT Audio**:

- **DAT Audio: Grabber** — an instrument that plays what the Grabber receives on its track. In
  Logic, put it on a Software Instrument track; in REAPER, add it as an instrument FX.
- **DAT Audio: Grabber (effect)** — the same, as an effect, putting the network **in place of**
  the track. For hosts that load only effects — Audacity, Audition, Premiere Pro, Final Cut Pro,
  DaVinci Resolve, Audio Hijack, Hindenburg — and, in Logic, an audio track with input monitoring
  on, which plays continuously.
- **DAT Audio: Sender** — an effect that sends its track over VBAN, to another Grabber,
  Voicemeeter or any VBAN receiver. The track carries on to its output as usual; turn off
  **Pass the track through while sending** to hear it only at the receivers. It sends the
  track, never the Mac's output, so nothing loops back.

The Grabber plugins' window is the Grabber app's own — every kind of stream, the list, trims, fold-down, mute and
solo, loudness, the meters, the themes — compact when it opens and full when widened, with **no
inserts** (use the DAW's), no output device (the DAW is the output, at its own sample rate) and
no Send (that is the Sender's). The Sender's window is the Send controls, with its own settings
(the gear): stream name, quality, resuming and auto-stop.

Hosts: Logic Pro, GarageBand, MainStage, REAPER, Ableton Live, Bitwig, Studio One, Digital
Performer, FL Studio and Ardour load all three; hosts that load only effects get the Grabber
(effect) and the Sender. Cubase, Nuendo, Pro Tools and Reason do not load Audio Units. (Only
REAPER has been tried so far.)

**Saved with the project.** A Grabber plugin keeps what was playing, each stream's fold-down and
channel order, and its level in the DAW project; opening the project plays those streams again
as soon as they are found. A Sender keeps its whole setup — name, quality, receivers, what it was
sending. Like the apps, a Sender only starts sending by itself if **Resume sending when opened**
is on. The look, buffers and discovery settings are shared by every project.

**Each Sender is its own stream**, named after its track when the DAW says what the track is
called (and following a rename of the track until you give it a name of your own), otherwise
"DAW Track 1", "DAW Track 2"… A new Sender starts with the receivers and settings of the last one.

**Each Grabber plugin is its own**, too: its own streams, mix and level, so two tracks can
play different streams (or the same one). A new Grabber plugin starts with the last one's settings,
playing nothing. A Grabber plugin tells the DAW its buffer as latency, so the DAW can line the network
up with the rest of the project. It starts listening only once it is used — its window opens,
a project gives it streams, or the DAW plays it — so a DAW scanning its plugins starts nothing.

Limits for now:
- **The app and a Grabber plugin can run together**: whichever starts second shares VBAN's port 6980
  and Scream's 4010. Senders offering on the network, and multicast Scream, reach both; a
  stream sent **straight** to this Mac's port (Voicemeeter, a Sender target typed by address,
  unicast Scream) reaches only the one that started first. The log says when this applies.
- **Settings changed in one plugin** reach new plugins opened after it closes, not the others
  already open.
- macOS may ask the **DAW** for permission to use the local network the first time.
- In Logic, a Software Instrument track renders when it is selected or record-enabled; to hear
  the network continuously, use the Grabber (effect) on an audio track with input monitoring on.

It is the same code as the apps — the Grabber and the Sender are libraries the plugins are built
from — so a change to either reaches the plugins. Code that only makes sense in an app checks
`AudioOutput.hostMode`.

## Network Audio Sender

> **Beta:** verified on a small number of Macs so far.

The Grabber's companion, built from the same package: **it sends what this Mac is playing as
plain VBAN** — everything by default, or only **chosen apps** (a browser's helper processes, where
its sound actually plays from, are included with it), or **one input device** (a microphone, an
interface's inputs, BlackHole or an aggregate device) taken whole at its own channel count. The
**Source** menu in the header chooses; the Grabber's Send has the same menu. An input device asks
for macOS's Microphone permission the first time. It is made for Network Audio Grabber first — **Connect to a Grabber…** finds one on
the network with nothing to type — and works with any other VBAN receiver too, such as Voicemeeter
or VBAN Receptor, by typing its address. macOS 14.2 or later, nothing to
install — it captures through a CoreAudio process tap.

To send, type the address the receiving Grabber shows under **Settings → Discovery → Send VBAN to
this Mac** and press Add. The port is VBAN's 6980 unless you change it. Each target is a row:

- **★** pins it to the top. Every target is remembered between launches.
- **▶ / ■** sends to it or stops. Nothing is sending when the app opens, unless "Resume sending
  when opened" is on in Settings.
- **BCAST** sends to the broadcast address of that target's network instead, so every receiver
  on it hears the stream. Only for a network this Mac is on.
- **M** mutes that target: it gets silence, so its receiver keeps listing the stream.
- **A name**: double-click the address, or right-click → Name…, to call it "Studio PC" instead.
  The address stays in the tooltip and is what Copy address copies. Names stay on this Mac.

The meters show what is being captured, not what the speakers play. **The Grabber and the Sender
itself are never captured**, so a Mac running both cannot send the Grabber's playback back out.
**Inserts** work as in the Grabber — three Audio Unit slots with BYP, the plugin's editor and an
optional dry/wet — and what is sent is the audio after them. With nothing loaded they are out of
the path. **You hear them at the receiver, not on this Mac**: the Sender captures what the Mac
plays before the inserts touch it. The same reason means there is no Δ in the Sender, since
nothing local can hear the difference.

It sends as many channels as the output device has — six on a 5.1 output, eight on a 7.1 —
unless Settings is set to Stereo. Settings also holds the stream name, 16- or 24-bit, "Mute this
Mac while sending", and the same appearance and colour scheme as the Grabber. A new stream name
takes effect on Return. The Grabber follows a rename of the Sender's stream, keeping it
favourited and joined — a workaround made for the Sender; other VBAN senders may or may not be
followed.

**Broadcast on this network** (the **Broadcast…** button beside + under Receivers) sends to every
VBAN receiver on a chosen network at once — several Grabbers, Voicemeeter — with nothing typed;
the row is "Everyone on en0", marked BCAST and LOCAL. Everyone on that network receives it, it is
not encrypted, and it never leaves the network. On Wi-Fi a broadcast slows everyone down, so
Findable by Grabbers is mostly the better choice there. **Keep broadcasting when opened again**
brings it back at launch **only on the same network** — told apart by its router, not just its
addresses — and a broadcast stops if the Mac leaves that network.

**Auto-stop** (Settings, off by default) stops sending to a target this Mac has been unable to
reach for the time chosen — the host is off or has left the network — and the row then says
**Timed out**. A target this Mac cannot reach right now says **Unreachable** either way, and
picks up as soon as the host is back. VBAN gets no reply, so a receiver that is on the network
but not listening cannot be told apart; that only works for hosts on the Mac's own network. A
Grabber listening through the offer that goes away is let go after 15 seconds regardless.

**Connect to a Grabber over VBAN…** (under ON THE NETWORK) walks through it: turn on VBAN in the other Mac's
Grabber, turn on **Findable by Grabbers** here, press play there, and allow it here.
Each Grabber on the network lists the stream, and it goes to each one you allow, and to nobody
else. **Ask before a new Grabber listens** is on by default: a Grabber you have not allowed yet
waits ("… wants to listen — Allow / Deny"), and the ones you allow are remembered by address
under Settings → Grabbers. Turn asking off and any Grabber on the network can listen when it
presses play.

**The log.** Settings → Log, in both apps, lists what the app did and why — each request, its
result, what stopped and why, and anything worth a look — with the time and a kind (Request,
Done, Failed, Stopped, Note, Warning). The newest 1000 entries are kept between launches, oldest
dropped first; **Export…** saves them as a text file.

**How safe the offer is.** It cannot be used against anyone else: audio only goes to an address
that proved it asked, a request never gets a bigger reply, requests are rate-limited, at most
eight listen, and anyone who stops checking in is dropped. It is **not private**: the audio is
plain, unencrypted VBAN, like all VBAN, so anyone who can see the network's traffic can capture
it, and a Grabber's name is whatever it says it is (its address is what is checked). Use it on a
network you trust — home, studio, office — and leave the offer off on public or guest Wi-Fi. Anyone on the network can ask for it, so it is off
until you turn it on, it only comes back on at launch if "Resume sending when opened" is on, and
every Grabber listening is shown by the name it reports. Nothing is captured or sent until one
listens. "Stop all" turns the offer off too. A target whose address belongs to a Grabber that
has listened shows that Grabber's name, unless you have given it your own.

**The first time it sends, macOS asks to let it record this Mac's audio. Allow it.** Until that
is granted the capture delivers nothing at all; the window says so and has a button to the right
page of System Settings (Privacy & Security → Screen & System Audio Recording → System Audio
Recording Only).

## Discovery

Three mechanisms for AES67, merged by multicast group and port, and VBAN beside them, each
switchable in Settings:

- **SAP** (RFC 2974) on `239.255.255.255:9875` and the legacy `224.2.127.254:9875`. This is
  what Dante-in-AES67-mode uses.
- **RAVENNA** — Bonjour `_rtsp._tcp`, then an RTSP `DESCRIBE` for the session's SDP. This is
  what Merging devices and ANEMAN publish; on many RAVENNA networks there is no SAP traffic
  at all.
- **Dante** — Audinate's `_netaudio-arc` / `_netaudio-cmc` / `_netaudio-chan` Bonjour
  services, used to identify devices and label their streams.
- **VBAN** — on by default. No announcements exist: a stream is listed when its packets
  arrive on UDP 6980. See **VBAN** above.

If a sender advertises nothing, the **paste-SDP** button in the toolbar takes an SDP block.

## Diagnostics

The same binary runs headless, which is the fast way to tell a network problem from an app
problem:

```sh
APP="build/Network Audio Grabber.app/Contents/MacOS/NetworkAudioGrabber"

# What is out there?
"$APP" --probe --iface en5

# Join one stream and report packets, loss, buffer and drift
"$APP" --probe --iface en5 --listen --only "Studio A"

# Same, but play it through the default output device
"$APP" --probe --iface en5 --listen --only "Studio A" --play

# List Dante devices
"$APP" --probe --iface en5 --dante
```

`--seconds N` sets how long it runs (default 15).

`--selftest` drives the real app state headlessly, which is how the plugin chain gets verified —
Audio Unit scanning needs a live run loop and `--probe` drives its own:

```sh
# Both insert slots, blended, printing the wiring that actually got built
"$APP" --selftest --insert "AUGraphicEQ" --insert2 "AUPeakLimiter" --mix 0.6

# Solo the rear pair of a 7.1 stream (channels are 1-based here)
"$APP" --selftest --iface en5 --only "Dub Stage" --mixmode downmix --solo 7,8

# Loudness on a real stream with the monitor output at zero — makes no sound
"$APP" --selftest --silent --iface en5 --only "Studio A" --seconds 30

# Post-insert peak at −72 dBFS: proves audio survives the dry/wet wiring, still inaudible
"$APP" --selftest --master 0.001 --iface en5 --only "Studio A" --insert "AUGraphicEQ" --mix 0
```

`--bypass` engages BYP on whichever slots were loaded, so bypass can be checked against the
same reading.

`--render <folder>` draws the interface to PNGs — both appearances and the compact window —
without needing a display.

## Testing without hardware

`Tools/test_sender.py` is a fake sender: it announces a session over SAP and streams L24/48 kHz
tones, a different frequency per channel.

```sh
# Terminal 1 — stays on this Mac, nothing touches a shared network
python3 Tools/test_sender.py --iface-ip 127.0.0.1 --channels 6

# Terminal 2 — lo0 is hidden by default, so ask for it
AES67_SHOW_LOOPBACK=1 open "build/Network Audio Grabber.app"
```

Then pick `lo0` in the interface menu. `--active-channels 3` restricts the tone to one channel,
which is how the downmix coefficients were verified. Use `--iface-ip <your NIC address>` to
send onto the real network instead.

`Tools/vban_sender.py` does the same for VBAN, to `127.0.0.1` by default, in any of its formats
(`--format i16|i24|i32|f32|f64`, `--rate`, `--channels`, `--drop` to lose packets). It also has
abuse modes for checking the receiver's limits: `--fuzz` (malformed headers — nothing may be
listed or decoded), `--flood N` (N made-up streams — at most 8 may be listed from one sender) and
`--flap` (a stream that keeps changing format). With VBAN on, or headless:

```sh
python3 Tools/vban_sender.py --format f32 --channels 6 &
"build/Network Audio Grabber.app/Contents/MacOS/NetworkAudioGrabber" --selftest --vban --only "Test VBAN" --silent
```

## Layout

| Path | What it is |
| --- | --- |
| `Sources/NetworkAudioGrabber/Discovery/` | SAP listener, SDP parser, RAVENNA/RTSP browser, Dante browser, VBAN listener |
| `Sources/NetworkAudioGrabber/Net/` | Interface enumeration, multicast socket |
| `Sources/NetworkAudioGrabber/Audio/` | Shared receiver core, RTP and VBAN decode, ring buffer, drift control, SMPTE downmix, BS.1770 loudness, AU host, CoreAudio output |
| `Sources/NetworkAudioGrabber/UI/` | SwiftUI views — the full window, the compact window, the signal panel |
| `Sources/NetworkAudioGrabber/Probe.swift` | `--probe` headless diagnostics |
| `Sources/NetworkAudioGrabber/SelfTest.swift`, `RenderPreview.swift` | development harnesses |
| `Tools/make_icon.swift` | Draws the app icon |
| `Tools/test_sender.py` | Fake AES67 sender for testing |
| `Tools/scream_send.py` | Fake Scream sender (a tone in Scream's format) for testing |
| `Tools/rtp_send.py` | Fake plain-RTP sender (no PTP; PipeWire/VLC-style) for testing |
| `Tools/vban_sender.py` | Fake VBAN sender, with fuzz, flood and format-flap modes |
| `Tools/vban_offer_test.py` | Tests the Sender's offer handshake as a hostile Grabber; `--grabber-fuzz` floods a Grabber's side |
| `Tools/reset-prefs.sh` | Starts both apps and the plugins afresh, as for a new user, after backing up their settings and logs; see *Starting fresh* |
| `Tools/vban_tone.ps1`, `Tools/vban_listen.ps1` | Windows, nothing to install: send a VBAN test tone; report the VBAN streams arriving |
| `Sources/NetworkAudioSender/` | The Sender: process-tap capture, VBAN transmitter, its window |
| `Sources/NetworkAudioShared/` | What both apps share: VBAN wire format, theme, meters, small controls |
| `Tools/lufs_test.swift` | Checks the loudness meter against closed-form answers |

## Uninstalling

1. In either app: **Settings → Remove all settings…** (in the Grabber it is under Settings → Log).
   It clears both apps, the Grabber's Send and the plugins, then quits. Quit the other app first,
   and close any DAW project with a DAT Audio plugin in it.
2. If you installed the plug-ins: **Help → Remove DAW Plug-ins…** in the Grabber; or, if they
   were installed for all users from the disk image, remove `DAT Audio Plug-ins.component` from
   `/Library/Audio/Plug-Ins/Components`.
3. Move **Network Audio Grabber** and **Network Audio Sender** to the Trash.
4. Empty the Trash.

That is everything. macOS's own permissions for the apps (audio recording, Local Network) are
dropped by macOS once the apps are gone.

## Starting fresh (resetting settings)

**Settings → Remove all settings…** in either app does it from inside, or, to open the apps as a new user would — for trying a new build, or when something is tangled —
quit Network Audio Grabber and Network Audio Sender (and close any DAW project with a DAT Audio
plugin in it), then run, from the project folder:

```sh
Tools/reset-prefs.sh --dry-run      # lists what would go, changes nothing
Tools/reset-prefs.sh                # backs everything up to the Desktop, then resets (asks first)
Tools/reset-prefs.sh --permissions  # also makes macOS ask again for audio recording
```

It removes, for both apps, their Send and the plugins: every setting, favourite, saved target,
Remote link, kept broadcast and activity log, and nothing else. A copy goes to a dated folder on
the Desktop first (`--backup DIR` for another place).

Where these live, if you would rather do it by hand:

| What | Where |
|---|---|
| Settings — the Grabber app, its Send, the Sender app | `~/Library/Preferences/app.networkaudiograbber.monitor.plist`, `….monitor.send.plist`, `app.networkaudiosender.send.plist` |
| Settings — the plugins | `~/Library/Preferences/app.networkaudiograbber.au.plist`, `….au.send.plist`, and one `….au(.send).p<number>.i<id>.plist` per plugin open |
| Activity logs | one folder: `~/Library/Application Support/Network Audio` (a file per app; older versions kept a folder per app, moved here on first use) |

Remove them with `defaults delete <name>` (the file name without `.plist`) rather than by deleting
the file alone: macOS keeps preferences in memory and would write a deleted file straight back.
To put a backup back, quit the apps, copy the files back into those folders, then run
`killall cfprefsd`. Two permissions are macOS's, not the apps': audio recording (reset with
`--permissions`, or `tccutil reset AudioCapture <bundle id>`), and Local Network (System Settings →
Privacy & Security → Local Network). DAW projects keep their plugins' own copies, which a reset
does not touch.

## If something looks wrong

| Symptom | Likely cause |
| --- | --- |
| Streams appear but no audio | Wrong interface picked — multicast only arrives on the NIC that is on the audio network. The log says so after 4 s. |
| RAVENNA and Dante vanish, SAP still works | Local Network permission denied. See **Build and run**. |
| `underruns` climbing | Buffer too low for this source, or a switch dropping packets. Raise the buffer. |
| Insert menus empty | macOS hasn't finished scanning Audio Units; reopen the menu after a moment, or restart the app. |
| Dante gear listed but no Dante streams | AES67 mode not enabled, or no AES67 multicast flow created. See **Dante**. Settings marks each device `AES67` or `no flow`. |
| A Dante Virtual Soundcard transmit never appears | DVS and Dante Via cannot do AES67 at all. Bridge through hardware Dante, or use a RAVENNA driver on that machine. |
| Nothing at all, no errors | Almost always a VLAN or interface problem. Confirm with `--probe`. |
| Nothing at all over a VPN | Expected. A remote-access VPN carries neither multicast nor mDNS — see **Remote access** below. |

## Remote access, and why a VPN will not do it

**The app has to be on a network that delivers the multicast.** A remote-access VPN — Cisco
Secure Client / AnyConnect, or anything of that shape — cannot, for three independent reasons,
any one of which is enough on its own:

1. **The receive path is multicast only.** `MulticastSocket` binds the group address and joins it
   with `IP_ADD_MEMBERSHIP` on the interface you pick. There is no unicast receive path, so
   there is nothing for a unicast tunnel to deliver into.
2. **The tunnel carries no multicast.** A remote-access VPN is a unicast TLS/DTLS tunnel. It
   passes no IGMP membership reports and does no multicast routing, so the join has nothing to
   join to on the far side.
3. **Discovery fares worse still.** RAVENNA and Dante are found over mDNS on `224.0.0.251`,
   which is link-local by design and never leaves its own segment. SAP is multicast to
   `239.255.255.255`. All three discovery mechanisms return nothing.

And if all of that were solved, the bitrate settles it. One 8-channel L24/48 kHz stream at 1 ms
packet time is about **9.5 Mbit/s on the wire at 1000 packets a second**, against a default
playout buffer of 15 ms. That is not a link-quality problem to be tuned around; it is an order
of magnitude more than a shared mobile connection will hold steady.

All of that is about AES67, RAVENNA and Dante. **VBAN is the exception**: it is unicast, so a
VBAN sender pointed at this Mac's VPN address (Tailscale, say) reaches it across the tunnel —
if the link holds the bitrate, about 1.6 Mbit/s for stereo 16-bit. Raise the buffer for it.

What does work for AES67, roughly in order of how much it sounds like the real thing:

- **Be on the audio VLAN.** With an IGMP querier, on the NIC you select in the toolbar.
- **Remote into a Mac that is** — Screen Sharing, ARD, or similar — and run the app there. Audio
  over a screen-sharing session is compressed and delayed: fine for "is there signal, and is it
  roughly right", not for judging a mix.
- **Run a contribution feed from site.** Something on the audio VLAN receives the multicast and
  re-streams it compressed and buffered over unicast — Audiomovers LISTENTO, Source-Connect, or
  a self-hosted Opus/SRT relay. This is what remote monitoring actually means in practice.
- **A layer-2 tunnel** (bridged OpenVPN, VXLAN between sites, ZeroTier with multicast) genuinely
  can carry multicast, and this app would work across it unchanged. It needs your network team,
  and it still needs the bandwidth above.

## Project documents

- `CHANGELOG.md` — what changed in each version.
- `docs/PROTOCOL.md` — the Sender ↔ Grabber wire protocol, version 1, with sample packets checked
  against the code (`--checkvban`): the contract for any other implementation.
- `docs/quick-start/QUICK-START.html` — the illustrated quick-start guide for new users, also
  in each app (Help → Quick Start Guide). After changing `QUICK-START.md`, run
  `python3 Tools/guide-to-html.py` and rebuild.
- `docs/ui-dark.png`, `docs/ui-compact.png` — the Grabber's full and compact windows;
  `docs/sender-dark.png` — the Sender.

## Limitations

- **Multichannel output is pass-through only.** Stream channel *n* goes to bus channel *n*;
  there is no routing matrix and no upmix. A stream wider than the bus folds to stereo on the
  first pair rather than being folded to an intermediate width — a 7.1→5.1 fold is a separate
  job. Inserts that cannot take the bus width are dropped from the chain rather than applied to
  part of it.
- The Grabber is receive only, and not a PTP slave. Sending is the Sender's job, and VBAN only.
- VBAN: PCM only (no VB-Audio codecs), 16/24/32-bit integer and 32/64-bit float; 8-bit is
  refused rather than guessed at. Late or reordered VBAN packets are dropped, as RTP ones are.
- Native Dante transport is not supported — AES67 mode is the bridge (see above).
- IPv4 only, which is what AES67 uses.
- Unencrypted SAP only; encrypted announcements are ignored.
- Audio Units only, not VST/VST3.
- Needs the network to carry the multicast: an IGMP querier on the audio VLAN, and this Mac
  on that VLAN. `--probe` with no results and no errors almost always means a VLAN or
  interface problem rather than an app problem.

## Footprint

2.9 MB app bundle, no dependencies beyond the system frameworks, around 40 MB resident.

CPU, measured rather than estimated, on one 8-channel 48 kHz stream with ten more discovered and
the signal panel open — 100 % is one core:

| | CPU |
| --- | --- |
| Idle, nothing joined | 0.7 % |
| Receiving, panel closed | ~6 % |
| Receiving, panel open, 30 fps meters | **8–10 %** |
| Receiving, panel open, 60 fps meters | ~15 % |

It was **24–28 %** until 0.9, and none of it was where it looked — not the audio path, which
never appeared in a profile at all. It was SwiftUI: the window's whole view tree laid out on every
display cycle because a `TimelineView` had invalidated, a packet counter published four times a
second, an announcement timestamp published on every SAP and RAVENNA announcement, and two
always-visible numeric readouts driven by `TimelineView`.

Single short samples of this app carry ±3–5 % of noise on a busy machine, so treat one reading
with suspicion — the wrong turns above both came from trusting one.

Every path in the build is relative to the project folder, so it can be copied or shared as-is.
