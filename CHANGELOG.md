# Changelog

Some older entries refer to internal design notes that are not part of this repository.

## 0.16.2

Mac and Windows built from the same engine, with the same version number.

### Added
- **Gone streams are told apart.** A playing stream whose sender has left (no audio for 30 s and
  no announcement either) moves to a folded **Gone** section under the list, above Ignored. It
  stays joined and plays again if it comes back; left alone it stops after 5 minutes and leaves
  the list. **Stop** or **Clear all** clears them sooner, and right-click → **Ignore this stream**
  moves one to Ignored. Streams added by hand (a pasted SDP, internet radio) are never stopped
  this way. In the compact window a gone stream says **Gone** instead of No packets. Before, a
  playing stream stayed listed for as long as it was joined, however long ago its sender left.
- **Sent audio is marked as priority traffic** (Mac). The Sender and the Grabber's Send mark
  their packets the way AES67 marks its audio (DSCP EF), and the Mac sends them in its Wi-Fi voice
  queue. Switches and access points that honour the marking pass the audio ahead of downloads and
  other bulk traffic, which can mean less jitter and fewer drops on a busy network; the rest ignore
  it, and nothing else changes. Not yet in the Windows build.

### Fixed
- **A renamed Sender keeps playing when its old name came from a broadcast.** A broadcast carries
  no identity, so a Grabber playing it could not tell that the Sender's later announcements, under
  a new name, were the same Sender, and the old name stayed listed. Its audio and announcements
  leave from one port, so the address and port now tie them together (found testing the Windows
  beta).
- **Quiet RAVENNA sessions stay listed.** Bonjour only reports changes, so a session nothing
  changed about was never asked for its description again and could drop out of the list after
  two minutes. Each one is now asked again every minute, and one that leaves Bonjour leaves the
  list at once instead of after two minutes.
- **A Dante device that leaves the network is forgotten.** Before, it stayed in the device list
  until the app was restarted. On Windows, only a device that says goodbye is forgotten; one
  unplugged without a goodbye stays listed until the Grabber restarts.
- **A stream asked for from a Sender keeps playing when the Sender is renamed.** It stopped
  instead whenever the new name was listed before the rename was recognised, and the Grabber
  then kept asking the Sender for the old name for good, so the stream never left the list or
  counted as gone. The log now says "this computer", not "this Mac", on Windows too.
- **Streams are labelled Dante only when they come from Dante.** A stream counted as Dante
  whenever its sender's address was a Dante device, so a PC running Dante software alongside
  another maker's AES67 driver had that driver's streams labelled DANTE (AES67). The label now
  comes from the stream's own announcement, which Dante marks as its own.

## 0.16.1

A small Mac update, alongside the first Windows beta offered for download (built
from the same engine; what's new in it is in its own README).

### Changed
- **Dante devices are found by default** (Settings → Discovery), on the Mac and on Windows. With
  it off, the same AES67 streams were labelled SAP on one machine and Dante on another. A choice
  already saved is kept.

## 0.16

First public release. Includes everything since 0.14, among it the 0.15 tester build.

> **Stable pre-Windows snapshot:** the last version before the shared engine and
> Windows work began — a backup of the previous version
> (source, both apps, the Audio Units). Go back to it if the port's restructuring breaks anything.

> **Not yet stable: VBAN receive and Network Audio Sender** are verified on one Mac only. They
> stay unstable until the release checks pass across
> real machines.

### Added
- **Choose the Grabber's output device:** the system default (as before) or any connected device,
  from the header or Settings → Output. A chosen device that is unplugged falls back to the
  default until it returns.
- **Choose what the Sender sends:** system audio (the default), chosen apps (a browser's helper
  processes included), or one input device at its own channel count — in the Sender and the
  Grabber's Send.
- **About window with scrolling credits** in both apps: what they work with (AES67, RAVENNA,
  Dante's AES67 mode, VBAN, Scream and more, each with its owner), what they are built with, and
  the trademarks — pausing under the pointer, still with Reduce motion on. **Licences…** shows
  every licence in full. Settings → Credits shows the same text.
- **Help → Install DAW Plug-ins (beta)…** in the Grabber: the plug-ins are carried inside the
  app and installed into your own Components folder in one step (no password, no Terminal);
  the same item updates or removes them.
- **A disk image** (`./build.sh release dmg`): drag the apps to Applications; the plug-ins
  (beta) can be dragged to Components for all users.
- **A plugin that crashes comes back by itself.** Inserts already ran in their own process, so a
  crash never stopped the audio; now the plugin is also reloaded, with its last settings, after
  a couple of seconds. If it crashes again within a minute it stays out until Reload is pressed.
- **The Remote link is encrypted end to end** (ChaCha20-Poly1305, from Apple's swift-crypto):
  only the two ends that swapped codes can hear it or send to it, and a link's rows say
  REMOTE · ENCRYPTED. Codes are longer (they carry each end's secret); codes and links from
  earlier builds must be made again. Local VBAN is unchanged.
- **The Quick Start Guide is a click away** in Settings and the connection windows, as well as
  under Help.
- **Help → Quick Start Guide** in both apps: the illustrated guide, carried inside the app and
  opened in the browser — listening, the four ways of sending, and the compact window and
  Detailed view. Nothing is fetched from anywhere.
- **A renamed Sender stays one stream** in the Grabber when it is Findable, however it renames
  (the Windows Sender restarted its counter, and left the old names listed).
- **Fewer places to clean up**: all logs in one folder (`~/Library/Application Support/Network
  Audio`; older ones move there); **Settings → Remove all settings…** in either app clears both
  apps and the plugins and quits — uninstalling is that, the apps to the Trash, empty the Trash.
- **`Tools/reset-prefs.sh`**: start the apps and plugins afresh, as a new user, with a backup
  first (README → Starting fresh).
- **"DANTE (AES67)"** on the source pills, the sidebar and Settings — the Grabber hears Dante
  devices in AES67 mode only. The Source column is a little wider for it; remote/local badges
  shrink to their symbols where a row is short of room, so stream names keep their space.
- **Remote links stand alone**: they no longer turn Findable on (or announce locally), keep
  working with it off, pause on Stop sending with a Resume, and say when to swap new codes. VPN
  streams are marked VPN and use the remote buffer. Every Sender's settings have "Ask before a
  new Grabber listens" and the allowed list. One way to broadcast: Broadcast….
- **Broadcast on this network**: one button sends to every VBAN receiver on a chosen network;
  "keep broadcasting when opened again" only ever resumes on that same network, and a broadcast
  stops if the Mac leaves it. Wi-Fi is warned about.
- **Remote streams have their own buffer** (Settings → Playout, 60 ms), with **Test the
  connection**: 30 s of listening, a suggested figure, and **Use**. Links show the other end's
  name and whether it is connected; a code from behind the same router points to On this
  network; codes say how long they are good for. The Remote link is in both plugins too.
- **Remote link**: a Grabber and a Sender in different places connect by swapping a code each
  way — nothing to open on either router; the sending end lets in only that Grabber (its exact
  address and port). Any number of links, listed with Unlink. The three ways to reach another
  place are radio headers, only the chosen one open. Remote rows say **NOT ENCRYPTED**. Plain VBAN
  underneath, marked REMOTE, not encrypted. In both apps' connection guides.
- **Connecting to another location**: Connect / Send… asks where the other end is. *Somewhere
  else* leads with the Remote link, then a VPN, then **By address** — supported, and marked advanced and not
  advised over the internet (an open port, unencrypted audio), with the same warning on every
  address field for an address outside this Mac's networks, and **Find this network's outside
  address** (one STUN request, only when pressed). Remote rows carry a **REMOTE** badge.
- **The receiving plugins are called DAT Audio: Grabber and Grabber (effect)** (were
  "Receiver"); IDs unchanged. They start listening only once used, never scan Audio Units, and
  log the plugin's version rather than the DAW's — REAPER no longer stalls opening with them.
- **Auto-stop** (off by default). Grabber: Settings → Playout → Auto-stop stops each playing
  stream once it has had no audio for the time chosen (1 min to 24 h); its row then says
  *Timed out*, and the tooltip says when and where the setting is. Send (the Sender app's
  Settings, the Grabber's Settings → Send): stops a target this Mac has been unable to reach for
  the time chosen. A target that cannot be reached now shows *Unreachable*. Off, nothing ever
  stops by itself, and joined streams play again when they return.
- **Grabber Settings → Send**: the Send's stream name, quality, channels, "Resume sending when
  opened" and auto-stop — the same controls as the Sender app's.
- **Each Grabber plugin is its own engine**: its own streams, mix and level, so Grabber plugins on
  different tracks can play different streams. **Grabber plugins report their buffer to the DAW as
  latency.** Scream's port is shared between the app and a Grabber plugin, as VBAN's is. Plugin
  settings files left by a DAW that crashed are cleaned up.
- **Plugins are saved with the DAW project**: a Grabber plugin's streams, fold-downs, channel orders
  and level; a Sender's whole setup. **Each Sender is its own stream**, named after its track
  (following the track's name until renamed), starting from the last Sender's receivers.
- **The Grabber app and a Grabber plugin can run together**: the second shares UDP 6980,
  finding and joining Senders' offers over a spare port while hearing their beacons on the
  broadcast address; only streams sent straight to 6980 stay with the first.
- **The Grabber's Send is named after the Grabber** until renamed, and follows a rename of it.
- **Three Audio Units, from DAT Audio**, each doing one job: **Grabber** (instrument),
  **Grabber (effect)** for hosts that load only effects, and **Sender** (effect), which sends
  its track — never the Mac's output — handed from the render thread to a send thread without
  locks, with **Pass the track through while sending** (on by default). A session with only
  Senders runs no receiving. The Grabber plugins open compact and have no Send. They replace
  "Network Audio Grabber: Grabber" and "(effect)"; component IDs changed.
- **Send, inside the Grabber**: Network Audio Sender's own controls — this Mac's audio to other
  receivers over VBAN, Findable by Grabbers, per-receiver mute — as a section along the bottom of
  the full window (open by default, resizable up to about 40% of the column, folds to one line),
  a Send tab in the new non-modal **Receive / Send** window ("Connect / Send…", and Help → Send
  This Mac's Audio…), and a Send tab in the compact window. **Mute all** keeps every receiver
  connected. A "Sending · N" pill in the status bar (and "Receiving · N" on the compact Send
  tab) takes you to the other side. Its settings and targets are its own, apart from the Sender
  app's; the Grabber's own playback is never sent. **Costs nothing until used**: no port, thread
  or timer until something is sent or offered, and it all stops again after. Not in the Audio
  Unit yet. The list's heading is now "Receive".
- **The stream filter can be a row above the list** (Settings → View → Stream filter), for a
  narrower window, with ‹ › to step along when it does not fit. The Audio Unit always uses the
  row; the compact window's filter is the same row, compacted.
- **The Grabber as an Audio Unit (first version)** for REAPER and Logic: an instrument and an
  effect, each with the Grabber's whole window — every stream type, trims, fold-down, mute and
  solo, loudness, meters, themes — without inserts or an output device. `./build.sh release au
  install`. Passes Apple's `auval` for both; checked in a test host with an AES67 stream and with
  Network Audio Sender over VBAN. Built from the same sources as the app.
- **Eight more schemes with their own look**, each in the style of an audio app's default look:
  *Lojick* (Logic Pro), *Abletron* (Ableton Live), *Wise* (Wwise), *FNod* (FMOD Studio),
  *MidTools* (Pro Tools), *Bitlick* (Bitwig Studio), *RogueSingleCell* (Audio Hijack) and
  *AudaTown* (Audacity). Like Rea-Theme Default, each sets the window and panel colours, the
  meters, faders, buttons and play button, and is always light or dark — Appearance is greyed
  out while one is chosen, and says why.
- **Source sidebar** in the full window: show all streams or one kind — RAVENNA, Dante, AES67,
  VBAN, Scream, internet radio, manual — with counts; remembered. The compact window has the same
  filter as small toggles above its Listening list.
- **REAPER's look for the Rea-Theme Default scheme:** square mint meters, fader caps, near-square
  buttons, a green play-stop button and REAPER's meter scale. Other schemes are unchanged.
- **Several rows open at once**, to compare streams. Pressing play opens a row only when none is
  open; stopping closes it.
- **Ignore a stream** (right-click → Ignore this stream): it moves to a folded *Ignored* section
  at the foot of the list, is remembered across launches, and *Show in list* brings it back.
  Settings → Discovery shows how many are remembered, with *Show all again*.
- **Remove a pasted-SDP stream** from the list (right-click → Remove from the list), and
  **Keep streams added from SDP** (Settings → Discovery, off by default) so a stopped one no
  longer leaves the list after two quiet minutes.
- **Settings → Sources:** every kind of stream the Grabber plays, how each arrives, and the
  switch or button each needs.
- **Appearance in the View menu** of both apps and in Settings → Theme; the header button is gone.
- The Connect sheet and the SDP sheet say where the beta sources are switched on.
- Copy SDP / Copy address on the signal panel's input strips too.

### Changed
- **Quick Start Guide corrected:** Way A's steps and the compact-window pictures now match;
  Done is marked; a new **Good to know** section covers channels, fold-down, which device plays,
  and what isn't possible yet.
- **Receive / Send → Receive → On this network** fills the window like the Send tab.
- **Open streams side by side are told apart:** a small gap between two open rows, where they
  used to run together as one grey block.
- **Pinned loudness is chosen in Settings → Loudness** (it was under View).
- **Network Audio Sender is now version 0.15**, in step with the Grabber and the plugins.
- **Release builds carry no trace of where they were built:** debug maps are stripped and no
  source path is compiled in.
- **First run:** both apps open in **dark** mode unless another
  appearance is chosen; the Grabber's **VBAN is on by default**, so a Sender made Findable shows
  up with nothing to switch on. Credits no longer list DAW trademarks.
- **Allowing is by Grabber, not by address:** a Grabber allowed on one of its Mac's addresses is
  let in from the others too, without asking again (local networks only; a Remote link stays
  by exact address and port). A Grabber denied this session is listed in Settings → Grabbers
  with **Allow**, which lets it in within 20 seconds — no relaunch.
- **Which network a stream is on:** with more than one network, a row's LOCAL badge names it
  (en5, say); compact with **Detailed** adds each row's source address.
- **Broadcast…** says when a network is already broadcast to (and when every one is), marks
  those in its menu, and starts on one that isn't.
- **Remote link** says **Waiting for the other end** until a link connects (it said Linked, with
  Waiting beneath); a link behind this end's own router is pointed out once this end's code is
  made; the Grabber's guide has **Test the connection** under its links.
- **The Audio Unit opens at full size**, and switches to the compact layout by itself when its
  window is made narrower, instead of a full layout cut off on every side. Its maker is now "Network Audio Grabber", so REAPER lists "Grabber (Network Audio
  Grabber)".
- **Unticking a network in the Sender's offer menu stops the Grabbers listening through it**: the menu now means "send on these networks". They stay allowed, so
  ticking it again lets them rejoin without asking. The log says how many stopped.
- **A playing Sender stream follows the Grabber's network** instead of becoming a second stream:
  switching the Grabber to another network, or hearing the Sender on two, now plays it once
  from the address on the Grabber's network and stops the other path (the log says so). The
  open detail (Detailed) and the name's tooltip show which address a VBAN or Scream stream is
  coming from.
- **Settings → Playout says which buffer is for which streams:** PTP (AES67, RAVENNA, Dante in
  AES67 mode), streams without PTP (VBAN, Scream, plain RTP); the device buffer is for
  everything, and internet radio keeps its own.
- **A Sender on several networks is listed once**, not once per address (it had shown
  three rows for one Sender). Beacons now carry the Sender's identity for the run; a Grabber
  keeps the address on its own network. Older Grabbers ignore the new field; older Senders are
  still listed per address. Checked on one Mac: 3 listings with the old Sender, 1 with the new. The identity is kept in the
  Sender's settings, so it is the same after a relaunch.
- **The log says how long the Audio Unit scan took**, and notes it if the window ever stops
  responding for more than a second — to tell a slow first scan from anything else.
- **The level history moves smoothly:** it redraws on each new sample instead of on a timer out
  of step with the sampling, which had drawn two samples one time and none the next.
- **Abletron:** the Detailed figures' warnings (jitter, underruns) are dark brown, not orange.
- **The per-channel bars in each row have no dark background** behind them, in every scheme:
  they are a glance at signal, and the background made each look like a dark patch.
- **"Reaper Default" is now "Rea-Theme Default"**, keeping REAPER's trademark out of the app's
  own labels. A scheme already chosen stays chosen.
- **"Current REAPER theme" is gone**: REAPER themes are managed in too many
  ways to follow reliably. Anyone who had chosen it keeps its colours, as a custom scheme.
- **A quiet Mac no longer drops its Grabbers:** the Sender keeps sending silence while macOS
  delivers no audio, so a Grabber keeps listing, and receiving, the stream.
- **Sliders and switches** are drawn in the scheme's colour (macOS 26 had drawn them grey).
- **Level before fold-down** in each row. **Rea-Theme Default's accent** is REAPER's grey-teal.
- **Lower CPU again:** a 1 Hz update while nothing plays, the Detailed figures drawn by AppKit,
  and the compact loudness row laid out once per resize — about a third less than before this
  round with one stream, and a fifth less with eight in Detailed.
- **Lower CPU**: meters no longer re-resolve their colours every frame, the level history rests
  when there is nothing to show, unchanged loudness figures and packet counters no longer redraw
  the list, and the Sender's status line redraws alone. About a third less CPU with one stream in
  the Simple view.
- **The compact window's rows** show every channel, the mute surround and the channel-solo badge,
  as the full window's do.
- **The Sender's minimum width** is 460, so the output device's name is not cut short.
- **The full window's new layout** (from the layout mockups):
  - **No Inputs section.** Each playing row shows every channel in its Level column, one
    hairline each, and several rows can be open at once.
  - **Signal panel, in chain order:** Inserts, then Output. Peak max and the loudness readings
    sit left of the meters, the meters at the panel's edge as tall as the window allows, with a
    dB scale and SMPTE names. The pinned reading leads, larger. The figures shrink together on
    wide buses (up to 16 channels and beyond) instead of wrapping. The separate Loudness section
    is gone from the full window; the compact window keeps its own.
  - **Narrower panel:** 272 pt, from 352; the window's minimum width drops to ~1030.
  - **A bar over the stream list** holds what acts on the list: its count, Filter, ACTIVE,
    Connect… and Add stream… (SDP Address… while internet radio is off). The header keeps only
    window controls; the status bar keeps Solo, Stop all and the log.
  - **First launch** lists every kind of stream the Grabber plays and the button or switch each
    needs, instead of only "Listening for announcements…"; the compact window has a short version.
  - **A muted stream's meters** have a dark red surround, on the row and in its open detail, so
    muted reads differently from silenced by another solo (grey alone).
  - The compact window's footer has a **+** to add a stream by hand.
- The M / S column is wider, so S is no longer clipped; the jitter and trim figures are a point
  larger.
- **Internet radio and HTTP streams (beta, off by default):** turn on Settings → Discovery →
  Internet streams, then paste a URL in Connect… → Internet stream. Icecast, SHOUTcast and plain
  HTTP; MP3, AAC and FLAC, decoded by macOS; .m3u and .pls playlists; the station's "now playing"
  title. Reconnects by itself if the station drops. Ogg and HLS streams are not supported yet and
  say so.
- **Beta switches:** Scream, RTP without PTP and Internet streams are marked BETA in Settings →
  Discovery and are all off by default. AES67, Dante and VBAN are unaffected.
- **Level history**: the last 30 seconds of the output under the meters, in muted greys, with a
  red mark wherever a stream's audio stopped arriving or its buffer ran out. On by default; turn it
  off in Settings → View.
- **Signal through each insert:** a small in → out meter pair beside BYP shows the level going
  into a plugin and coming out of it.
- **Search for a plugin** from an insert's menu ("Search…" above the per-maker lists).
- **A stream that can't be joined says why on its own row**, for example "Port 5004 is in use by
  another app on this Mac", with Try again.
- **A REAPER colour scheme.** *Rea-Theme Default* uses REAPER 7's own default colours and its look (see above). (A second scheme that followed the theme REAPER was
  using was added here and later removed.)
- **The Sender's header shows its network and output device**, as the Grabber's does: a menu of
  the networks the offer to Grabbers is announced on — all of them (the default), or any number
  ticked, since a Mac can be on several at once — and the output device being captured with its
  rate. A ticked network that is not connected is listed so it can be unticked, and the offer is
  not announced on networks nobody chose. "Send to" addresses are unaffected.
- **Plain RTP streams without PTP (beta, off by default: Settings → Discovery)** — PipeWire, PulseAudio, VLC, GStreamer — play in the
  Grabber: announced over SAP or added by hand, multicast or sent straight to this Mac, L16 or
  L24, including RFC 3551's static 44.1 kHz types that name no format. They use the buffer for
  streams without PTP (Settings → Playout, now always shown and labelled for what it is).
  `Tools/rtp_send.py` imitates such a sender.
- **Scream receive in the Grabber (beta).** Scream is a free virtual sound card for Windows that sends
  the PC's audio over the network; each PC sending it appears in the list by itself ("Scream from
  …"), multicast or unicast, 16/24/32-bit, up to 64 channels, with the VBAN buffer. Off by
  default: Settings → Discovery → Scream. `Tools/scream_send.py` sends a test tone in its format.
- **The Sender can offer its stream to Grabbers on the network** (VBAN stage 3). Turn on
  *Offer to Grabbers on this network*: every Grabber on the network lists the stream by itself,
  and it goes to each one that presses play, unicast, and to nobody else. It's off by default and
  only comes back on at launch if "Resume sending when opened" is on. Every listener is shown by
  name, and nothing is captured until someone listens. The handshake uses a cookie bound to the
  Grabber's address, so the Sender can't be tricked into sending audio anywhere that didn't ask
  for it. Listeners that stop checking in are dropped after 15 s, and at most 8 listen at once.
  The audio itself is still plain VBAN.
- **The Sender asks before a new Grabber listens** (on by default, Settings → Grabbers): "Booth
  Mac wants to listen — Allow / Deny". Allowed Grabbers are remembered by address and listed with
  Remove; the Grabber's row says *asking…* meanwhile, or *declined*. Off, any Grabber on the
  network may listen as soon as it presses play.
- **A Log tab in Settings, in both apps.** Each entry has a time, a kind (Request, Done, Failed,
  Stopped, Note, Warning) and what happened, e.g. "Joining “Edit Suite Mac” — VBAN from Network
  Audio Sender at …", "Refused: the Sender's user declined this Grabber", "Timed out: no answer
  from the Sender …", "Interrupted: no audio for 4 s … Asking again". It's kept between launches
  (the newest 1000 entries, at most 256 KB, oldest dropped first) and filterable to Problems.
  **Export…** saves it as a text file named with the app and the date and time, headed with the
  version, macOS and the time range covered. The Grabber's drawer under the list shows the same
  log.
- **Connect to a Sender over VBAN…** in the Grabber, beside the stream list's STREAM title: the
  same four steps from the Grabber's side, adding a Sender by address, and which way to connect.
  Both connect buttons first say plainly that the audio isn't encrypted and to connect like this
  only on a network you trust, such as at home, in a studio or an office (Continue, Continue and
  Don't Show Again, Cancel).
- **Connect to a Grabber over VBAN…**, the Sender's main way in: four steps that tick themselves off, and
  a short *Which way to connect* in both apps (same network, over a VPN, any other VBAN receiver).
- **A small emblem of each app's icon in its header**, with the app's name beneath, muted so it
  reads as a label, not a button — in the Grabber's full and compact windows and the Sender's.
- **Grabbers tell a Sender their name** (Settings → Discovery → Network Audio Sender, the Mac's
  name by default), and the Sender shows it against the listener and against a target with that
  address, unless you've named the target yourself ("Use reported name" in its menu).
- **Add a Sender by address** in the Grabber, for a Sender over a VPN or anywhere its offer can't
  reach.
- **`--checkvban`** (34 fixed checks of the handshake format and cookie) and
  **`Tools/vban_offer_test.py`** (12 live checks against a running Sender, plus a fuzz mode aimed
  at the Grabber).
- **Names for the Sender's targets.** Double-click a target, or right-click → Name…, to call it
  "Studio PC" instead of an address. The address is in its tooltip and is still what Copy address
  copies. Names stay on this Mac; nothing is sent. Targets saved before this load unnamed.
- **VBAN has its own buffer, 20 ms by default** (Settings → Playout, shown while VBAN is on). VBAN
  usually arrives over Wi-Fi or a VPN: a test round was clean at 18–22 ms over Wi-Fi
  and started to underrun at 16. AES67 keeps its own buffer, still 15 ms by default. An install
  that had already set the one shared buffer keeps that value for both.
- **When the last underrun happened**, beside the underrun count in a stream's figures, so buffer
  tuning can go by data rather than by ear.
- **`--checkdefaults`** in both apps: checks the new defaults and the migration of old settings
  against throwaway preferences, and exits non-zero if any case fails.
- **New icons for both apps.** Both are built from the same two elements: a thick U (a pot) and
  a file of three amber packets. On the Grabber the packets drop in from the top left, shrinking
  as they reach the U. On the Sender the U turns its back and the packets leave to the top right,
  growing as they go, so both icons read left to right. The icons differ in outline, not just
  colour, so they stay distinct in greyscale, for colour-blind users and in macOS 26's Clear and
  Tinted modes. They use the default Graphite & Amber colours: bone on graphite with amber
  packets for the Grabber, graphite on warm cream with burnt-amber packets for the Sender, 7.1:1
  apart in lightness as well. The 32 and 16 px versions have fewer, larger packets snapped to
  whole pixels. The old bars-and-arcs design was dropped because it sat too close to other audio
  apps' icons. The design was chosen over ten rounds of mockups.
- **Inserts in the Sender** — the same three slots as the Grabber, with the same hard
  BYP, dry/wet (shown if Settings asks), latency-aligned dry leg and Δ, plus the plugin's own
  editor. The audio is sent after them and the meters read it after them. Plugins, their
  settings, bypass and blend are remembered. With nothing loaded they are out of the path
  entirely. Verified with the Grabber's own null test from the Sender: Δ across a transparent
  limiter sends silence with packets still flowing, dry delayed 2.0 ms; Δ across a lowpass sends
  a real difference; no plugin leaves the tone untouched.
  - **Shared, not copied:** the plugin catalogue, slots, delay-and-invert unit and the wiring
    around each insert moved from the Grabber into `NetworkAudioShared` as `InsertChain`. The
    Grabber's output now uses it, and reproduces every recorded insert result: Δ null −∞ with
    2.0 ms compensation, lowpass Δ −73.3 dBFS, 50/50 blend −72.0 dBFS aligned, two slots chained.
- **The Grabber follows a renamed VBAN stream**. Renaming the stream in the Sender
  used to leave one Grabber entry per name — the favourite and the joined stream stayed on the
  old name, and each old name lingered for 15 s. The favourite, joined state, mix mode and
  channel order now move to the new name and the old entry goes at once. **A workaround made for
  Network Audio Sender**, recognised by same address and port, same format and an unbroken
  frame counter; other VBAN senders may be followed too, but that is best effort and unverified.
- **Sender, from use:** the stream name is applied on Return or on leaving the field, not per
  keystroke (which put every partial name on the wire); **every target is remembered**, with ★
  pinning it to the top, plus an optional "Resume sending when opened"; **the channel count
  follows the output device** — six on a 5.1 output, eight on a 7.1 — with "Stereo" as the
  alternative in Settings, and one meter bar per channel; the toolbar no longer repeats the app's
  name. Verified: rename followed with 0 lost; targets kept across relaunch and resumed when
  asked; an 8-channel 24-bit stream into the Grabber, 0 lost, folded 7.1 → 2.0.
- **Network Audio Sender** (VBAN stage 2). A second app in the same
  package that sends what this Mac is playing as plain VBAN. macOS 14.2+, captured through a
  CoreAudio process tap and a private aggregate device — no driver. Type the address the
  Grabber shows, press Add; the port defaults to 6980. Per target: ★ favourite (remembered),
  ▶/■ send, **BCAST** (that network's broadcast address instead), **M** (send silence, so the
  receiver keeps the stream). Live meters of what is captured, a status line with the bitrate,
  and Settings for stream name, 16/24-bit, "Mute this Mac while sending", appearance and the
  Grabber's colour schemes.
  - **The Grabber and the Sender are never captured** — by process, and on macOS 26 by bundle
    identifier too — so a Mac running both cannot loop the Grabber's playback back out.
  - Follows output-device and sample-rate changes and sleep/wake, rebuilding the capture.
  - **A missing recording permission is named, not mistaken for silence**: a capture that is
    running but delivers no callbacks at all says so, with a button to the Privacy page.
  - Verified with `--selftest --tone` into the Grabber on this Mac: 16-bit (256 frames a packet)
    and 24-bit (239), 0 lost, the Grabber reading exactly the 0.250 peak sent and −12.7 LUFS.
    **Capture verified** once the permission was granted: a test tone captured at −38.1 dBFS on
    both channels, 188 packets a second, and the Grabber receiving it with 0 lost, −38.8 LUFS and
    −7 ppm drift. The permission survives a rebuild.
  - **Fixed before release**: with an audio interface as the output device, its own
    microphone input arrived ahead of the tap in each callback and was read as the left channel,
    while the tapped stereo was read as the right — twice the packet rate, garbled audio. The
    output device's input buffers are now skipped.
- **`NetworkAudioShared`**, a library both apps link: the VBAN wire format (the Grabber's reader
  and the Sender's writer in one place), the theme, the AppKit meters and the small controls.
  Moved out of the Grabber unchanged; its renders are pixel-identical before and after, and its
  AES67 and VBAN self-tests read the same.
- **`Settings → Discovery` says how to send VBAN here** once VBAN is on: every address this Mac
  has — wired, Wi-Fi and VPN, each labelled and copyable, with each network's **broadcast
  address** beside it — and the port, read from the machine
  each time the pane is drawn, with a line on which to use. A VPN address is listed because the
  listener accepts on it, which already covers a sender elsewhere on the same VPN (Tailscale,
  say). If the port could not be opened, the reason is shown there too. The render harness
  shows made-up addresses from documentation ranges. Broadcast receive needs nothing
  new — the listener binds every address — and `Tools/vban_tone.ps1` now enables broadcast on
  its socket, which Windows otherwise refuses, so a PC can test it.
- **VBAN receive** (stage 1). Voicemeeter, phone VBAN apps and anything
  else sending VBAN are listed beside the AES67 streams, tagged `VBAN`, and join, fold, meter and
  measure like any other. **Off by default** — `Settings → Discovery → VBAN (UDP 6980)`, whose
  footer says what address to point a sender at. 16/24/32-bit integer and 32/64-bit float PCM,
  any VBAN sample rate (resampled to the device as usual), loss counted from the frame counter.
  A stream is listed while its packets arrive and leaves 15 s after; one that changes format is
  rejoined, at most every 2 s.
  - **Hardened against floods**. One socket for all VBAN; a packet is header-checked and
    nothing more unless its stream is joined; at most 32 streams listed, **8 per sender**, 4 new
    a second; the window only updates when a stream actually changes. Floats that are NaN or
    infinite are zeroed so they cannot poison the loudness meter. Measured with the new
    `Tools/vban_sender.py`: a 200-name flood takes 8 slots while a real stream from another
    address plays with 0 lost and 0 underruns; ~10 s of fuzzing lists and decodes nothing; the
    window stays at 0 updates a second through both.
  - `--selftest --vban` switches it on for a headless run. The render harness gains a VBAN row
    and `ui-settings-discovery.png`, with a made-up interface so no real address is captured.
  - AES67 is untouched: IDs, favourites and saved listening lists are unchanged, and the
    loopback self-test reads the same with VBAN off, and with it on and receiving alongside.
- **The full window rebuilt around one line per stream**. A joined row was three bands
  and about 74 points, so six of twelve streams fitted a full-height window; it is one line of
  30 now and they all do. Nothing was taken off the row to get there — the space came from the
  address and format line, which repeated the same string under every name and is now shown
  once, under the stream you have open. **Trim, mute and solo stay on the row**, because
  balancing three streams against each other should not need a selection first.
  - **One stream is open at a time**, with its detail in place under its own row: channel
    meters and the channel solo, and beside them — not below, where they left the middle of
    the window empty — either the stream's own facts or every arrival figure the receiver
    keeps. Joining a stream opens it; a stream that is filtered out or leaves the network
    closes it.
  - **`Settings → View → Stream list: Simple / Detailed`**, replacing `Compact rows`. Simple is
    name, source, channels, where it goes, level and trim. Detailed adds a jitter column and
    the eight figures the app has always measured and never displayed: jitter, worst jitter,
    buffer, low water, drift, lost, underruns, packets. The jitter warning is a quarter of the
    playout buffer rather than a fixed number, because 0.4 ms is nothing behind 15 ms.
  - **The panel is 352 points rather than 268**, and its INPUTS section is now a strip: one
    block per joined stream, thin unlabelled bars, so the streams you are *not* looking at stay
    visible — losing sight of them is how a silent or misrouted channel goes unnoticed.
    Clicking one opens it in the list.
  - **A third insert slot.** Two was what fitted a 268-point panel, not a considered number.
  - **The insert header carries the chain's added latency** beside the available-plugin count,
    which delta already measures per slot.
  - The app's name sits quietly at the top left, in spaced serif capitals.
  - Measured either side with `--render --hold`: **unchanged at rest** (mean 6.2 % against
    6.3 %), about 1.1 points more while a row is open, which is that row's meters and its 4 Hz
    poll.
- **Channel order is a choice, per stream**. `SMPTE — L R C LFE Ls Rs` (the default and
  what broadcast and game audio use) or `ITU/DTS — L R Ls Rs C LFE`. Nothing in an AES67 or
  Dante stream declares its order, so it can only ever be an assumption; this makes the
  assumption changeable instead of merely visible. `Settings → Fold-down → Channel order` sets
  the default and a stream's own menu overrides it, because the order belongs to the sender and
  two devices on one network can disagree. The order decides the fold-down gains, the channel
  labels, which channel is excluded as LFE, and which carry the +1.5 dB loudness weighting — and
  on a wide bus it becomes a permutation, since the bus is always SMPTE-ordered and a stream is
  mapped onto it by role. Menu items spell the order out rather than naming a standard. Offered
  only where the channel count has roles to assign.
  - Internally this came from pulling a `ChannelRole` out of the fold-down builder, which no
    longer knows about layouts at all — it walks the roles in the order they arrive.
  - `--selftest` prints per-channel bus peaks at every width now, not only wide ones: on a
    stereo bus the left/right balance is how an order mistake announces itself.
- **Multichannel output**. The monitor bus can be as wide as the output device allows —
  stream channel *n* to bus channel *n*, no routing matrix — chosen from a menu beside the output
  meters (and in Settings → Output) and **remembered per device**, keyed by its UID. A 16-output
  interface offers stereo, 4.0, 5.1, 7.1 and its full width, because a device that wide is
  rarely a room that wide. Stereo stays the default: fold-down reaches whatever you are
  listening on, where matching the device reaches only what is wired to your ears.
  - Streams that fit the bus play out channel for channel (`5.1 direct`, `7.1 direct`) and
    fold-down stops applying to them; wider streams still fold to stereo on the first pair;
    narrower ones leave the rest of the bus silent, because pass-through never upmixes.
  - A remembered width the current device cannot carry falls back to stereo and says so, without
    forgetting the choice.
  - **Loudness is now BS.1770-weighted across the bus** — surrounds +1.5 dB, LFE excluded, the
    rest at unity; a width with no SMPTE layout counts every channel at unity rather than
    inventing a weighting.
  - **The master meters draw the whole bus**, bars thinning as it widens, with SMPTE names where
    the layout has them and numbers where it does not.
  - **An insert whose plugin cannot take the bus width is held out of the chain** and named as
    such, rather than being quietly applied to the front pair. `channelCapabilities` is asked
    before the plugin is connected.
  - `--selftest --bus N` sets the width, and prints per-channel bus peaks so pass-through can be
    checked without a rig. Measured on a 16-output device: an 8-channel stream puts −72 dBFS on
    all eight bus channels; a 6-channel stream on the same bus leaves 7–8 silent.
- **Delta monitoring on the inserts**. `Δ` beside `BYP` on each insert: hear only what
  that plugin changed — `wet − dry`, Reaper's delta solo. The parallel pair supplied
  the topology; the two things an `AVAudioEngine` graph cannot express are now one in-process
  Audio Unit in the dry leg that **delays by whole samples and inverts**, because mixer gains
  clamp at zero and there is no delay compensation. Without the delay the subtraction
  comb-filters instead of nulling, showing a difference the plugin never made.
  - Delta overrides dry/wet at unity, as Reaper's does, and the knob returns when Δ is released.
  - One insert at a time; it clears itself on bypass and when the plugin changes.
  - The log says what it compensated, and says plainly when a plugin reports no latency and
    nothing is being compensated.
  - Verified both ways: a transparent plugin reporting 2.0 ms subtracts to **−∞ dBFS**, and a
    filter that alters the signal leaves **−73.3 dBFS** against a −72.0 dBFS programme — so
    delta is not merely silencing the bus.
- **Each stream remembers how it was last listened to.** The mix mode is persisted per stream
  (`mixModes`, keyed `group:port`) and restored when it is rejoined, including the rejoin the app
  does at launch. Before this the mode lived on the receiver, so a 7.1 bed went back to its first
  pair every session. A remembered mode is validated against the channel count that actually
  arrives, so a stream re-announced narrower than it was does not come back with its menu naming
  channels that no longer exist.

### Added
- **A loudness reading pinned beside the compact window's peak figure**, at nearly the
  same size, so the number you judge by is readable across a room.
  `Settings → View → Pinned loudness`; integrated by default, and `None` turns it off.
- **Every slider resets to its default on a double-click**, in both windows — monitor
  level to unity, a stream's trim to 0 dB, a dry/wet to fully wet, the buffer to 15 ms. The
  sliders are now AppKit (`ResettableSlider`): a SwiftUI `Slider` never receives a double-click
  gesture, because the `NSSlider` underneath takes the mouse for its own drag tracking.
- **The loudness readings reset on a double-click too** — the pinned figure, the folded
  summary row and the block. Folding a section now happens only on its name, so resetting a
  reading beside the name no longer folds the section instead.
- **The compact window says how many outputs the device has**, beside the sample rate, and its
  bus menu reads `2 of 16 ch` rather than `Stereo`.

### Changed
- **The Grabber's right-hand panel folds.** Inserts and Loudness each fold to a one-line summary,
  as in the compact window, so the Inputs section above gets more room; the output never folds.
  Inserts starts folded; a failed insert still shows in red while folded.
- **Meters show when nothing is arriving.** A joined stream with no packets, or a Sender that
  isn't capturing, draws a row of dots instead of an empty bar, so it can't be mistaken for
  silence.
- **A crashing plugin no longer takes the app down.** Inserts run in macOS's separate plugin
  process where the plugin allows it. If that process dies, the insert is taken out of the
  chain, the audio carries on, and the slot turns red with a Reload button that restores its
  last settings.
- **Meters move in step with the display** (a display link rather than a timer), and the levels
  the audio passes to the meters are shared safely between threads in both apps.
- **Lighter on the CPU.** The compact window uses about 40 % less CPU, and Detailed and Simple
  about 10–15 % less. Detailed stopped redrawing twice as often as it needed, and the signal
  panel stopped rebuilding itself to change one number. The jitter column now also stays current
  in rows that are closed. `Tools/many_senders.py` runs dozens of test streams for measuring.
- **Colour fixes.** In light mode, yellow accents darken to gold rather than olive. Teal & Coral's
  coral is now #FF7F50, further from Mute's red; anyone who chose it keeps the preset. Both apps'
  Connect buttons now read "Connect…".
- **The Sender is simpler.** The stream's name is the headline (click it to rename), with this
  Mac's address under it for anyone connecting by hand. Everyone receiving is in one Receivers
  list: *Findable by Grabbers* (formerly "Offer to Grabbers on this network") sits in its heading,
  and + adds a receiver by address. Broadcast, rename, favourite and remove are in each row's "…"
  menu, with a BCAST badge only while broadcasting. Inserts fold away. **Connect…** is in the
  status bar, where the Grabber has its own.
- The Grabber's column titles show even before any stream has been found.
- **A cleaner look for both apps.** Flat stream rows instead of tinted cards, with a
  status column that says "OK", "No packets" or "Asking…" in words; sentence-case headings; the
  accent colour kept for what is switched on. The output section is taller, with the peak and
  integrated loudness large, the level in dB rather than a percentage, and DIM and MONO filled
  with the accent when on. Loudness rows are named Short-term, Window and Integrated, with the
  target in the heading. Dry/wet is shown on every insert by default. The compact window's
  readouts are larger and say how far off target they are ("+0.2 against −23"), and its inserts
  are the full window's. The Sender puts targets and listeners in one Receivers list, shows a
  listen request as its own card above it, and draws its inserts exactly as the Grabber does.
  Colours that washed out in light mode (source chips, loudness offsets) now darken there.
- **Appearance (System / Light / Dark) is in Settings → Theme** in the Grabber, beside the
  colour scheme it shades; it was under View. The Sender's matching section is called Theme too.
- **A clearer header in both apps:** the app's mark at 22 points with its name beside it,
  "Grabber" or "Sender", instead of a small mark with a tiny caption beneath. The header is
  44 points tall in both apps; the Grabber's compact window has the same at 18 points. Chosen
  from four mockups : a separate header was kept
  rather than moving the controls into the title bar.
- **Both apps now need macOS 14.2 (Sonoma) or later.** The Sender always did; the Grabber
  needed 13. One requirement for the pair, and it lets both use SwiftUI's newer observation,
  which redraws only the parts of a window whose data changed instead of the whole window.
- **The default colour scheme follows the system** (for a while it was
  Graphite & Amber). Graphite & Amber is one choice away in Settings → Theme. The on/off switch is gone:
  **System colour scheme** is now the first choice in the picker, and means the system's own
  colours, which was the default look before. Editing a colour makes a custom scheme. Anyone who
  had set the colour scheme, on or off, keeps exactly what they had.
- **The Sender has no Δ any more**, and its inserts say *"Inserts are applied to the stream only —
  you will hear them at the receiver, not on this Mac."* whenever a plugin is loaded. The Sender
  captures what this Mac plays *before* the inserts, so nothing local can hear their effect or
  the difference they make. The inserts themselves stay, for uses like a spatial plugin making a
  fold-down for the receiver. The Grabber keeps Δ.
- **The receiver is split from its transport** (VBAN stage 0). Buffering,
  drift control, fold-down, gain, meters and arrival figures move into `StreamReceiver`;
  `RTPReceiver` keeps only its socket, sequence tracking and big-endian decode. Discovery intake
  also takes a parsed description, with SDP parsing as a wrapper over it. No behaviour change:
  the loopback `--selftest` gives the same packet, loss, peak and loudness figures before and
  after (−12.8 LUFS stereo, −12.7 LUFS 5.1 → 2.0, 0 lost), and the release build has no
  warnings. It exists so a second transport is an addition rather than a copy.
- **The pinned loudness reading is in the full window too**, beside the peak figure in
  the panel. It had only ever existed in the compact window, which is where it was asked for.
- **Toggling DIM restarts the peak maximum**. The figure is a max-hold measured after
  the monitor gain, so a maximum captured at one monitor level says nothing about the next —
  which read as the readout being slow to recover. The clip latch is left alone, because
  clipping happened whatever the monitor was set to afterwards.
- **The inputs strip says what each stream is doing to reach the bus** — `7.1 → 2.0`,
  `Ch 1/2` — rather than only how wide it arrives, and names a channel solo — `S Lrs Rrs`,
  outlined where the whole-stream badge is filled — so greyed bars read as a choice rather than
  a fault. The two are different things: a channel solo selects within one source and leaves
  every other source playing, where the filled `S` silences the rest.
- **Simple shows one fact under an open stream**, the group address. Source, channel
  count and format are already on the row or identical for every stream on the network, and the
  second row of cells made every open stream taller for nothing.
- **The three loudness readings each have their own explanation** in Settings, saying
  what each is for rather than only how long its window is.
- **The in-window title was removed** one turn after being added: it duplicated the macOS window
  title.

- **The output sample rate is a picker over what the device supports, not a "Set to 48 kHz"
  button**. `Settings → Output → Sample rate` lists the rates the hardware reports and
  goes both ways; the old button could take a device from 44.1 to 48 kHz and offered nothing to
  put it back. It shows the current rate even if the device does not enumerate it, and the log
  says plainly that this is the device's own setting and every application will see the change.
- **A pinned loudness reading is only offered when loudness readings are shown**. With
  `Settings → View → Show loudness readings` off, the pinned-loudness picker is disabled and
  dimmed, and the compact window shows no pinned figure.
- **The master meters are more responsive, and match the compact window's**. They always
  shared one envelope; what differed was length — the compact window's horizontal bars are two
  to five times longer than the panel's were, so the same fall covered far more ground. The
  panel's bars are now 136 points rather than 104, and the master release is 0.22 s rather than
  0.30.
- **The folded loudness row no longer repeats the pinned reading**. With room for two it
  shows the two that are not pinned; with room for one it shows the pinned one, since by then
  the line above has dropped it. Shedding down to short-term
  made no sense when the figure pinned at the top — the one being judged by — was integrated.
- **The compact window's floors are measured rather than guessed**: 330 points wide,
  which is what the folded loudness row needs for all three figures, and a height base of 322
  for the folded state. 240 was too mean — it stacked "48 kHz" vertically — and a 300-point
  height clipped the last fold header and put a scroll bar in a window with nothing to scroll.
  The stream rows also still counted 44 points each from before they became two lines; 52 now.
  Whatever width you leave it at is remembered. Its own
  `minWidth: 320` is gone — in a narrower window that made the content wider than the window, so
  the horizontal output meters ran off the edge instead of shrinking. The peak row now sheds its
  label and then the pinned reading rather than wrapping.
- **The compact window folds by section**. `LOUDNESS`, `INSERTS` and `LISTENING` each
  carry a disclosure and each remembers itself; the monitor strip does not fold, because it is
  what the window is for. Defaults: loudness and inserts folded, listening open.
  - A folded section keeps a **summary** on its header — `LISTENING` names what is playing,
    `INSERTS` names what is loaded, and `LOUDNESS` gives all three figures across one row
    instead of four. Folding costs the detail, never the fact.
  - The loudness summary sheds figures rather than widening the window: `S W I`, then `S I`,
    then `S`, whichever fits.
  - The window follows the folds — `WindowShaper` takes its height from the content's floor and
    holds the top edge, so folding shrinks it and unfolding grows it back.
  - Audited control by control against the previous layout: nothing was dropped in the move.
- **The compact window is a control surface again, not a display**. Five things the full
  window could do and it could not: choose the network interface (it was a label, not a menu),
  choose a plugin for an insert, open a plugin's own window, set a stream's mix mode and channel
  order, and load an insert at all — the inserts section only appeared once a slot was already
  full. All present now, and the sample rate moved up beside the output device where the full
  window has it, with the output-bus menu taking its place beside DIM and MONO.
  - Four controls became shared views — `InterfacePicker`, `InsertPluginMenu`,
    `InsertEditorButton`, `StreamMixMenu` — so a control cannot be added to one layout and
    forgotten in the other. Two copies of the plugin-grouping helpers and one of the mix menu
    went with them.
  - Still deliberately absent from the compact layout: per-channel input meters, the diagnostic
    figures, the search box and `ACTIVE` filter, the manual-SDP sheet, the log pane, and the
    appearance cycle (which lives in Settings).
- **Tooltips now say what a control is doing, not just what it is for**. Every hover is
  two parts — what the control is, then its live state — in one shape, `tooltip(_:now:)`. Δ
  names the delay it is compensating, or says the plugin reports none; dry/wet gives the
  percentage and the alignment; BYP and Δ each explain how they differ from the other; ACTIVE
  says how many of how many; DIM and MONO say whether they are in the path; the master meters
  say when they are showing a difference signal rather than the programme; an input block says
  what its stream is actually sending to the bus. The three loudness readings now explain what
  separates them, which is only their window. macOS supplies the hover delay.
- **A dry/wet blend no longer comb-filters.** The delay line built for delta also aligns the dry
  leg for any blend, so the halves sum — measured on a plugin reporting 2.0 ms, a 50/50 blend
  reads −72.0 dBFS, the same as full wet, where misaligned it would be −72.6. Applied whenever
  the plugin is in circuit rather than only at partial settings, so moving the knob does not
  move the timing under you. This removes the caveat that shipped with it and the Outstanding entry
  that went with it; what remains is that a plugin *under-reporting* its latency still combs,
  and BYP is still the only path with no insert latency in it.
- **The dry/wet slider is hidden by default** — `Settings → View → Show dry/wet on inserts`. It
  is the widest control in an insert row and the least reached for, and Δ answers what it is
  usually opened for. Hiding it changes no balance already set.
- **Fold-down is now automatic for quad, 5.1 and 7.1 streams** — reversed from opt-in, and this entry says why rather than the earlier one being quietly edited. The discrete-feeds risk that made it
  opt-in is real and unchanged; what changed is that the guess is now made once per stream
  instead of once per session, so being wrong costs a menu click rather than recurring. Turn the
  automatic part off in Settings → Fold-down.
- **Quad joins the automatic rule.** `4.0 → 2.0` had always been in a stream's own mix menu but
  was left out of auto-fold, so the switch meant different things at different channel counts.
  Both now ask `SMPTELayout.foldsDown`.
- `MixMode` has one text encoding (`downmix`, `pair:2`, `mono:5`) used by both the preference and
  `--mixmode`, instead of a parser that existed only in the self-test.
- **The monitor path is no longer stereo-only, and the bus is still stereo.** Groundwork for
  multichannel output, deliberately invisible: `MixTap` carries destination channels,
  `RingBuffer.mixStereo` became `RingBuffer.mix` over an array of bus pointers,
  `RTPReceiver.render(left:right:)` became `render(into:busCount:)`, and MONO and the master gain
  run across N channels with LFE excepted — it is a band-limited effects channel, so it sits out
  of the fold and keeps its own signal. The audio thread still allocates nothing: the per-frame
  sums use a stack scratch buffer. Verified by A/B against the pre-change build on a 6-channel
  test stream — output peak −68.1 dBFS and S/W/I −12.6 LUFS on both, with `--probe --listen`
  reading −15.0 dBFS at 440 Hz, exactly a 0.25-amplitude sine through a pair tap.
- **`CoreAudioDevice.outputChannelCount`** reports how many output channels the device presents,
  summed over its output streams, and `--selftest` prints `device N ch   bus 2 ch`.
- **Settings is a sidebar of panes instead of one long popover**. The same seven sections
  — Playout, Fold-down, Discovery, Output, Loudness, Theme, View — are now picked from a list and
  shown one at a time, as `Form`s in the grouped style, so labels align themselves instead of
  being hand-set to a 96-point column. Every long explanation moved into a **ⓘ disclosure** that
  is shut by default; the short consequential lines stay on screen as section footers. Nothing
  was dropped and no section was renamed, so the README's `Settings → Loudness` references still
  hold.
- **Settings opens in the window, not a window of its own.** It takes over the stream list, which
  keeps the signal panel, the master meters and the status bar visible beside it — so the buffer
  can be tuned while watching the jitter and underrun figures it is being tuned against. **⌘,**
  toggles it, as does the gear, which now lights while it is open; **Done** closes it. The
  compact window shows the same panes, picked from a row of icons.
- The Output pane also states the **device and its sample rate**, with the 48 kHz switch beside
  the rate rather than on its own.
- The interface-menu example in 0.14's notes gave a real-looking LAN address; it now reads
  `en0 — <address>   Wi-Fi`. The synthetic `192.0.2.x` set used by the previews, `--render` and
  `Tools/test_sender.py` is invented and stays as it is.
- `--render` now also writes `ui-settings.png` and `ui-settings-compact.png`, so the pane is in
  the synthetic screenshot set like every other surface.

### Fixed
- **The plug-ins' Licences window was empty in a DAW:** it looked in the DAW's own bundle. It
  now reads the licences from the bundle the code is in (the app's, or the .component's).
- **The Sender app credited AudioUnitSDK,** which only the Grabber and the plug-ins contain.
  The credit now shows only where its licence is bundled.
- **Capturing a device with more than 64 channels** (system audio or an input) could send
  scrambled audio: a single interleaved buffer wider than 64 was read at the wrong stride. The
  first 64 channels are now copied out correctly.
- **A broadcast stream stopped and started every second** in a Grabber that also heard its
  Sender's offer on another network: the Grabber kept moving the playing stream to the offer.
  A stream whose audio is arriving is no longer moved; the Sender no longer offers on a network
  it broadcasts to; a move is logged as a move, not as "you stopped it"; and a stale
  **Declined** clears once audio arrives, so the row opens again.
- The main-thread watchdog only started after the Grabber's name was changed; it starts at launch now.
- **With the system colour scheme, the two apps disagreed:** the Sender's menus, Connect button
  and appearance icon were blue where the Grabber's were the native label colour. The Sender
  turned the system accent into a fixed copy of it, which also stopped it following a change of
  accent while open. Both now pass the live accent on untouched, and draw menus, the Connect
  button and the appearance icon the same way.
- **Light colours in light mode.** Canary, gold, lime and other light *active* colours washed out
  on a light window: pale menus, stop buttons, switches, sliders and borders. The active colour
  now adapts by itself — as chosen in dark mode, the same hue darkened to about 3:1 against the
  window in light mode (canary reads as gold, gold as ochre, lime as olive). Solo keeps its
  yellow fills in both; the "SOLO" and "Clear" text darkens in light mode. Both apps.
- **A malformed stream announcement could crash the Grabber if played:** one with a zero sample
  rate, an enormous channel count or a zero packet time was accepted. Announcements with formats
  no real stream has are now ignored. Found by a new fuzz check that throws random and damaged
  packets at every parser (`--fuzzcheck`).
- Every stream's Detailed figures now say how it keeps time: its PTP clock, or "sender's own
  (no PTP)" for VBAN. The source label's tooltip says the same.
- **The Grabber's output meters now keep time with its input meters.** They were fed in 100 ms
  blocks, so they trailed the inputs by up to a tenth of a second; they are now measured on
  every buffer sent to the device (~11 ms). Still after everything — master, DIM, MONO, the
  inserts and the limiter — and the insert chain's routing is unchanged.
- Detailed view's figures cost less to redraw.
- **"macOS is delivering no audio… allow System Audio Recording" appeared on a quiet Mac**
  with the permission granted: macOS captures nothing while nothing plays. It now appears only
  while another app is actually playing.
- The Sender no longer re-cleans the stream name and allocates for every packet on its capture
  thread; the name is prepared once when it changes.
- **The Grabber's window used about half a core in Simple view** after the narrow-window fix:
  the way the Connect button chose its label re-measured on every update. It now decides from
  measured widths, and the window is back to ~8 % of a core.
- The Sender's meters fall at the same speed as the Grabber's.
- **Development builds are signed with a stable local identity** when this Mac has one, so the
  Sender keeps its recording permission across rebuilds (README → "A stable signature for
  development").
- **Help menus said "Help isn't available".** Help now has the connection guide ("Connect to a
  Sender/Grabber over VBAN…") and Show Log, in both apps.
- **Pauses in the audio are logged.** When no audio arrives for over a second, the Grabber logs
  how long for. A pause lands in the "worst" jitter figure (a 4.2 s pause reads as 4176 ms with
  nothing lost), which looked like a network problem when it was the Sender not sending.
  The Sender logs each time its capture is rebuilt, and why: the output device or sample rate
  changed, the Mac woke, or the Grabber opened. Nothing is sent while that happens.
- **A Grabber already playing a Sender's stream never asked to join it**, so the Sender sat at
  "press play" and its user was never asked, until the stream was stopped and played again. It
  happened when the stream started playing before the Sender's announcement was heard — from a
  plain "Send to", or rejoined at launch. The Grabber now remembers what is playing and asks as
  soon as the announcement arrives.
- **The Sender's meters stepped once or twice a second when only Grabbers were listening.**
  They were paused unless a "Send to" target was on, and only redrew when something else did.
  They now run whenever anything is being sent. The "speakers are muted" line had the same
  mistake.
- **"Nothing is arriving… allow Network Audio Sender" appeared when the Mac was simply quiet.**
  It now appears only while another app is actually playing and the Sender still hears nothing.
- **Both apps now tell macOS they are busy while audio flows**, so App Nap cannot slow their
  timers when the window is covered or in the background. The Mac can still sleep.
- **At its narrowest the Grabber's window cut off the right-hand panel** and squeezed the
  STREAM title to "STR / EAM". The Connect button shortens to "Connect…" instead.
- **The Sender's window scrolled at its minimum height.** Its minimum now follows its content
  (up to the screen's height), and it grows when a listener, a request or a target is added.
  It never shrinks by itself.
- **The Discovery switches in Settings looked sluggish:** each restarted every browser in the
  middle of its own animation. The restart now waits a moment, and several switches flipped
  together cost one.
- The Grabber's switches and sliders use the theme's colour, as the Sender's already did.
- While a Sender's user was being asked, the Grabber warned "No packets… pick it in the network
  menu". It waits until the answer now. The Wi-Fi warning is said once per interface, not on
  every restart of discovery.
- The Sender's Send to hint said the Connect button was below it; it is above.
- **The Grabber's window used about a third of a core with a stream's row open in Detailed
  view** (found with Instruments). The figures' 4 fps timeline made SwiftUI update the
  whole window on every display frame, 90 times a second on a 120 Hz screen. It now runs on
  its own timer and updates only the figures: about 12 % of a core with the row open, 7 %
  without.
- **Much less CPU in the Grabber's window while a stream plays**. The level meters
  are now Core Animation layers moved by one shared clock rather than bars redrawn by the CPU on
  a timer each, and they rest while the window is hidden. The open row's figures in Detailed
  view no longer follow a 120 Hz display's refresh. The insert slots' plugin menus rebuild only
  when the list or the choice changes. Same look.
- **A blank panel could sit over the Sender's window for about 30 s at launch**. The
  window opened with the stream-name field focused, which starts macOS's text services and most
  likely their suggestion panel. The field no longer takes focus at launch, and the Sender's text
  fields no longer use autocorrect or Writing Tools.
- **Switching output devices no longer leaves the app silent**. Going from a 48 kHz
  interface to the 44.1 kHz built-in speakers and back left the engine stopped on the
  interface — the app believed it was playing and nothing came out until it was relaunched.
  `AVAudioEngine` stops itself when the hardware under it changes and says so only through
  `AVAudioEngineConfigurationChange`, which nothing listened for, so the engine was rebuilt for
  the new device and then stopped again by the change that caused it. Now both that and the
  default-device change feed one coalesced restart, made once the hardware settles and then
  *checked* — running, and on the device the system says is the default — with a few retries
  and a log line if it still cannot. `--selftest --flipto <device>` switches the default output
  to that device and back, silently, and reports where the engine really renders: before the
  fix "STOPPED, 0 callbacks" after switching back; after it, running with one restart per switch.
- **The output meters fall to zero after "Stop all"**, instead of freezing at the level
  the stop caught them at. They stopped redrawing the moment nothing was joined, and a paused
  meter keeps its last frame; muting did not show it because muted streams stay joined. The
  meters now run on until the output is below −100 dBFS — the bars in under a second, the
  peak-hold marker about ten seconds later — and then stop, so idle CPU is unchanged.
  `--selftest --stopafter N` presses "Stop all" part-way through and reports when they settle.
- **No real or copied addresses anywhere in the project**. A sweep of source, tools and
  docs for addresses, subnets, clock IDs, hardware addresses, interface names and paths found one
  real address (in the new PowerShell example), the real audio and Wi-Fi subnets in the Wi-Fi
  notes, a PTP clock ID with a real vendor prefix, and this Mac's interface names. All gone.
  Every example is now from a block reserved for documentation — `192.0.2.0/24`,
  `198.51.100.0/24`, multicast `233.252.0.0/24`, and IEEE's documentation EUI-64 for clock IDs —
  so none can match a real network. What remains is what the protocols fix (SAP, mDNS,
  loopback). The render harness now uses a made-up interface for every shot, and the
  screenshots in `docs/` are regenerated from it. The test sender's default group
  moved to `233.252.0.100` and was re-verified.
- **The compact window did not come back at the size it was left at** — the fourth
  attempt, and the first with a test. The shaper hung off `.background` on a view whose identity
  changes with the window mode, so every switch destroyed it and rebuilt it with no memory of
  which mode was applied; the branch three earlier fixes had gone into was never running. It is
  a stable sibling now, and the bookkeeping lives on `AppState` rather than in a view that can
  be rebuilt. A second cause behind it: the hosting view re-applies the previous mode's content
  minimum asynchronously and clamped the window back up, so a size is now recorded only from
  the user's own resize — never from a measurement of the window — and the target is
  re-asserted after the clamp arrives. `--render <dir> --modeswitch` drives the real window
  through both directions and passes or fails.
- **The full window could be dragged short enough to erase the panel's inputs section**,
  leaving a header with nothing under it. The floor is computed from the panel's own sections
  and the section holds its own 104-point minimum, so at the floor it shows a stream, part of
  the next and a scroll bar.
- **The full window's minimum width was 1000 in one place and 1080 in another**, which
  is how a window gets dragged narrower than its own content.

- **The compact window still forgot the size it was left at**, after two fixes that were
  both real faults and neither the cause. The size was recorded on *every* view update, and the
  mode-switch resize is animated — so the first update after switching read the window
  part-way through the animation and stored that. It is recorded on `didEndLiveResize` and on a
  mode change now, never from a view update, and the mode switch no longer animates.
- **The pinned loudness reading beside the peak now resets on a double-click**, as the
  loudness rows do and as the same figure already did in the compact window.

- **Every label in the interface failed contrast, in both themes**. Section headers
  measured 2.47:1 in dark and 1.65:1 in light against a 4.5:1 requirement, column titles 1.50:1
  and 1.19:1. `.tertiary` and `.quaternary` were the house style for labels across 39 call
  sites and cannot pass — below `.secondary` the hierarchical styles resolve to 25 % and 10 % of
  the label colour. Labels now use `Color.mutedLabel`, defined per appearance because one alpha
  cannot serve both themes; everything clears 4.5:1, closest 5.03:1. Hierarchy comes from size
  and weight instead.
- **No control in the app had an accessibility name**. 47 tooltips, zero
  `.accessibilityLabel` — and `.help()` supplies the accessibility *help*, not the name, so
  every icon-only control was announced as an unlabelled button and no toggle announced its
  state. Names, values and the selected trait are attached throughout; M and S speak as "Mute"
  and "Solo" with the stream's name; the meters are marked as decorative, since a bar redrawn
  30 times a second has no value to read and its figures are text beside it.

- **Δ was greyed out on every plugin restored at launch**, and came back only when an
  unrelated plugin was loaded. `rebuildChain()` never reported a status change, and whether a
  slot can offer Δ is derived from the built chain — so restored plugins had working delta
  units and an interface that did not know it.
- **The compact window forgot the size it was left at**. On a mode change the window was
  grown to the incoming mode's floor *before* the outgoing size was recorded, so switching to
  the full window wrote the full window's minimum width into the compact window's memory.
- **Double-clicking a stream's trim slider reset it and folded the stream away**. Only
  the name and the chevron open a row now.
- **Settings jumped back to Playout when the window mode was switched** — from inside the
  View pane, which is where the switch lives.
- **The inserts section looked different in the two windows**: boxed in the full window,
  bare in the compact one.
- **Nothing was open after the launch rejoin**. Joining a stream opens it, including the
  rejoin, when nothing else is.
- **Slot reads are bounds-checked** after three `EXC_BAD_ACCESS` reports inside
  `InsertSlotView` from the previous build. Hardening, not a diagnosis.

- **The compact window's output meter drew past the right edge of the window** — the
  fault behind four rounds of "the bar doesn't span properly". SwiftUI sizes an
  `NSViewRepresentable` from its intrinsic size, which the meter built from a length the compact
  window measured with a `GeometryReader` around that same meter: the layout read a dimension it
  also determined, so on a shrink the bars kept the previous window's length. `MeterStrip` now
  takes the width it is proposed and the `GeometryReader` is gone. `--render` grew
  `compact-shrunk.png` and `compact-grown.png`, captured by resizing a laid-out window rather
  than building a new one, because a first layout can never show this.

- **The compact window's output meters drew past the right edge after switching window modes**, at every width and every bus width. The meter views are layer-backed `NSView`s and had
  no `layerContentsRedrawPolicy`, so AppKit scaled the previously drawn contents into the new
  bounds instead of asking them to redraw — a strip drawn at 500 points squeezed into 330 keeps
  its old proportions and still reaches where the window used to end. Both views set
  `.duringViewResize` now and repaint on `setFrameSize`.
- **Collapsing every section in the compact window left a scroll bar**. Raising a window's
  minimum size does not grow a window that is already smaller than it — macOS applies a minimum
  to the next resize, not the current frame — so the floor was right and nothing applied it. The
  window is now resized up to its floor whenever it sits below it.
- **The Budget box in Settings → Playout clipped its figures on a narrow window**. A
  grouped `Form` row took its height from the first line; it now has a minimum height and is
  free to exceed it.
- **The compact window's output meter had L and R the wrong way round**. An `NSView`
  origin is bottom-left, so horizontal rows laid out at `slot * i` put channel 0 at the bottom
  while their labels ran top-down. Present since those meters were written, and invisible until
  a bus wide enough to leave rows empty made it obvious.
- **The compact window's output meter showed two bars whatever the bus was**. It now
  draws a row per bus channel inside a fixed 72-point block, labelled where a row is tall
  enough to hold a character.
- **The compact window could be dragged under its minimum width again**, taking the top
  bar with it: the floor has to be on the view as well as the window, because
  `.windowResizability(.contentMinSize)` derives the window's floor from the content.
- **The compact window's loudness and peak figures froze after a reset**. They read
  `state.readouts.…` from views observing `AppState`, but `Readouts` is its own
  `ObservableObject` — so they refreshed when something *else* published rather than when they
  changed, which after a reset is never. Two small views now take the object directly, as the
  full window's loudness block always did.
- **The compact window's output meter was clipped along its bottom edge**. Two bars in an
  11-point slot need 22 points and the frame gave them 18. The bars and their labels now derive
  from one constant.
- **Folding every section scrolled the fold headers out of sight**. The window's minimum
  height counted only the *open* sections, so it snapped shorter than the content it was still
  showing. The floor now includes the header, the monitor strip, the three fold headers and the
  footer, with the stream list's share capped at three rows.
- **The compact window's output meter kept the width it was first drawn at**. It takes its
  length from the view's bounds, and a layer-backed `NSView` given a new frame keeps its existing
  bitmap, so a resize changed nothing until a level happened to move. `setFrameSize` now marks
  the meters and their labels dirty — the third variant of one root cause, after a bus-width
  change and a bar-count change.
- **Whole ranges of plugins were missing from the insert list**. The app
  enumerated `kAudioUnitType_Effect` only, on the stated reasoning that music effects are
  note-driven — but `aumf` means "an audio effect that also accepts MIDI", not an instrument
  (those are `aumu`), and plugins move between the types across versions: FabFilter's Pro-Q 3 is
  `aufx` while **Pro-Q 4 is `aumf`**, as is the rest of their range. Both types are enumerated
  now, in two stages — effects first and published on their own, then music effects added — so
  the deadlock the restriction originally worked around would degrade to the old behaviour
  rather than to empty menus. It no longer reproduces: 59 music effects in under 10 ms with the
  engine running. The unit count went from 381 to 440 here.
- **The master meters went blank after the bus was narrowed** — bars and labels both,
  while the same width looked right from a fresh launch. An `NSViewRepresentable` handed a new
  frame across a change of bar count and slot size does not reliably survive it, so both meter
  views are now keyed on their geometry and a width change builds a new view. `--render` also
  captures the narrowing in place now, which is the only way this class of fault shows up.
- **The master meters kept a previous bus width's bars on screen**. They are drawn by
  their own timer rather than by SwiftUI, and that timer is stopped while nothing is playing —
  so a width change set the new bar count and never repainted. Geometry changes now force a
  redraw, paused or not.
- **A `needs N ch` chip crushed the insert controls**, squeezing BYP into a
  one-character column. Pills now fix their own size and the plugin name truncates instead.
- **Channel labels drifted left of their bars on the input meters**, most visibly on a
  stream set to `Ch 1/2` or `direct`, where single-digit labels sit under wide slots. Two causes
  in turn: a SwiftUI `HStack` of framed `Text`s packs by natural width, and then
  `NSAttributedString.draw(at:)` — the AppKit replacement — lays each string out from where the
  last one finished rather than at the point given. Each label is now drawn into its own
  slot-sized rect with centred alignment, which is what the arithmetic intended all along.
  Verified by measurement: bar centres and label centres both step by the slot width.
- **Master meter labels collided, truncated, or bunched under their bars**. They are
  drawn by AppKit now, sharing the meter's own slot arithmetic instead of mirroring it in a
  SwiftUI `HStack`, where short names packed by natural width and stopped matching the bars. The
  names are abbreviated to fit the slot — `LFE` to `LF`, 7.1's `Lss`/`Lrs` to `Ls`/`Lr` — rather
  than the slot being widened to fit the names, which pushed the readouts off the panel. Past
  eight channels only every fourth channel is marked.
- **Loading a plugin collapsed a wide bus back to stereo**. `rebuildChain` built a
  hard-coded two-channel format, left from before the bus could be widened, so loading or
  clearing a plugin — or toggling the safety limiter — rebuilt the graph at stereo while the
  meters and the loudness weighting went on believing it was wide.
- **A plugin held out of the chain for being too narrow said so only in the log**. Which
  made Δ look broken on a stereo-only plugin: it is disabled because there is no chain to take a
  difference across, and nothing on screen said why. The slot now carries a `needs 16 ch` chip,
  Δ's tooltip gives the real reason, and the log says what to do about it.
- **A stream stayed on the front pair when the bus was widened.** Two faults, one symptom:
  pass-through was never offered in a stream's own mix menu (it existed as the default for a
  wide bus and nowhere else), and a mix mode remembered from when the bus was stereo silently
  outranked the wider bus. Remembered modes are now keyed **per stream and per bus width** —
  `Ch 1/2` on a stereo bus is the whole of what that bus can carry, while the same choice on a
  16-channel bus is a deliberate restriction, and they are not the same preference.
- **The engine's last hop was stereo regardless of the bus.** `AVAudioEngine` connects its own
  main mixer to the output node at two channels, so a wide bus reached a stereo mixer output and
  a discrete-layout fold to stereo is silence, not a downmix — healthy loudness readings with
  every output meter at −∞. The final connection is now made explicitly at bus width, and
  `--selftest` prints the channel count at each hop (`source → mixer(8→8 ch) → device(8 ch)`).
- **An insert control could be thrown at a plugin that was not wired yet.** Instantiation is
  asynchronous, so a slot has its name the instant it is chosen and its node a moment later;
  `AudioOutput.isSlotLive` now separates the two and the Δ control is disabled until the plugin
  is actually in the graph, instead of silently doing nothing.
- **Markdown in Settings printed its own asterisks.** `Text("… **total** …" + "…")` is a `String`,
  not a literal, and `Text` only parses markdown from a literal or a `LocalizedStringKey`. Both
  affected paragraphs are now keys. Inherited from the popover.
- **The device buffer read `1 024`.** `Text("\(size)")` runs the interpolation through a
  localized key, which inserts a thousands separator; `Text(verbatim:)` does not. The unit also
  moved into the row label, where the segmented control can no longer overlap it.

### Notes
- **`--mockup <dir>` draws layout proposals for the full window**, wired to nothing and
  built from the app's own state-free components. Three layouts are: a dense one-line
  list with a wider panel, a monitor dock along the bottom, and a three-pane list/selected
  input/master rail. Nothing in the app has changed for them. The capture needs the display
  awake — the window server returns a blank frame otherwise, and the harness now refuses to
  write one rather than overwriting a good mockup with it.

- **Measured whether any of this cost performance**, against the pre-multichannel build
  with the same harness: interface idle 7.3 % → 7.4 % of a core, audio path on release builds
  2.2 % → 2.1 %, and a 16-channel bus 1.9 %. No change within the noise.
  `--render <dir> --hold <seconds>` holds the window up with meters running so the interface can
  be sampled with `ps` — no audio device, no sound.
- **Multichannel output is now a decided design rather than an open question**. Pass-through, not routing: stream channel *n* to bus channel *n*, SMPTE at both
  ends. Stereo with fold-down stays the default, and one control — `Output bus: Stereo (fold
  down) | Match device (N ch)` — carries the interlock: a wide bus turns fold-down off for
  streams that fit, stereo caps the bus at two however wide the device is. A stream wider than
  the bus folds to stereo on channels 1–2 and says so; a narrower one lands in the first
  positions with the rest silent, because pass-through never upmixes. An insert whose plugin
  cannot take the bus width is flagged and held out of circuit rather than quietly applied to the
  front pair — `AUAudioUnit.channelCapabilities` answers that before the plugin is connected.
  Apple's safety limiter needs no special handling: `auval` reports it handling the symmetric
  configurations up to 8-8. Still open: what MONO means across a wide bus. Nothing implemented.
- **Delta monitoring on the inserts is now tracked as a planned addition**. Reaper's per-FX delta solo: monitor `wet − dry` so only what the plugin changed is
  audible. The parallel insert pair already puts the topology in place, so the write-up
  is mostly the two parts it cannot express — polarity inversion, since mixer gains clamp at zero,
  and sample-accurate delay compensation on the dry leg, without which the difference comb-filters
  instead of nulling — plus what it does to the meters and the loudness figure, and a null-to-
  silence check that `--selftest` can actually assert. Nothing implemented.
- **Sender platform hints may not key on a custom name**. The
  heuristic matches only the driver or vendor token the middleware itself generates (`ASIO`,
  `CoreAudio`, `ALSA`, `JACK`, `PipeWire`, a manufacturer prefix), as a whole token from a fixed
  table with no per-setup entries; the user-chosen remainder of a service or session name — host
  name, session label, renamed workstation — is opaque, and stays out of tooltips and logs.
  A rule built on names seen on one network works on that network and nowhere else.

## 0.14

### Fixed
- **Wi-Fi was being classified as a wired NIC, and became the default interface**. Wi-Fi
  was always listed — the interface filter has always been on capability, not media type — but
  `isEthernet` was `!name.hasPrefix("ap")`, which is wrong twice: `ap1` is the *hotspot*
  interface, and the Wi-Fi client on a Mac is `en0`. Since the list sorts wired-first then
  alphabetically, `en0` sorted ahead of `en5`/`en6`, so on a fresh install with Wi-Fi connected
  the app picked **Wi-Fi** as its default interface — the opposite of what that sort was for.
  Wi-Fi is now identified by CoreWLAN, which reports the hardware whether or not it is switched
  on, and ranks behind wired.

### Notes
- **A scoped roadmap is now kept as planned work**: more receive protocols (VBAN
  first), VPN support for unicast transports, encoded/non-PCM payload detection, sender platform
  hints, Settings as a proper window, a VBAN companion transmitter, an identification audit and
  rebrand, and a git repository plus a basic website. Each entry carries the open design question
  and the trap rather than just the intent. Nothing implemented.
- **Multichannel output is now tracked as a planned expansion**.
  The monitor bus is stereo end to end: on a 5.1 or 7.1 interface you get the stereo mix on
  channels 1–2 and silence on the rest — measured by rendering a stereo chain into both layouts.
  The write-up carries the scope, the open design question (surround pass-through versus
  arbitrary routing) and the part most likely to derail it, which is that room-correction and EQ
  Audio Units are frequently stereo-only. Also newly stated as a limitation in the README, which
  had never said it.

### Changed
- `NetInterface` carries a three-way `kind` — wired, Wi-Fi, loopback — instead of a boolean, and
  the interface menu says which is which (`en0 — <address>   Wi-Fi`). Loopback is no longer
  lumped in with Wi-Fi in the ordering, and sorts last.
- **Selecting a Wi-Fi interface logs what is different about it**, once: an access point may not
  forward multicast, may rate-limit it to the slowest associated client, or may flood it — so a
  stream can be discovered and still deliver nothing — and arrival jitter is far higher than on a
  switch, so expect to need a much larger buffer. The README has the longer version.


## 0.13

### Fixed
- **Dropped the red `M` from streams a solo silences**. It marked *every* other stream,
  which is noise rather than information — the solo is already evident from the `S`, from the
  grey bars and from the `SOLO` flag in the status bar. And because the check sat in an `else if`
  beside the explicit-mute one, a stream that was also muted by hand drew **two** `M` badges.
  `M` now means one thing: you muted this stream.
- **Channel names in the panel switch to SMPTE whenever a channel solo is engaged.** With a solo
  on an unfolded stream the caption read `Solo L` while the label under the bar read `1`, and the
  chips on the row read `L` — three names for one channel. A channel solo is defined in SMPTE
  positions, so the panel now follows suit and all three agree.


## 0.12

### Changed
- **Mute and solo are legible in the signal panel.** They were bare 8 pt coloured letters that
  disappeared against the panel, and channel solo faded the excluded bars to 22 % opacity, which
  read as *quieter* rather than *out of circuit*. Now there is one rule stated everywhere:
  **a coloured bar is reaching the output, a grey bar is not** — covering a muted stream, a stream
  silenced by another's solo, and the channels outside a channel solo. Grey is a flat fill, not a
  dimmed gradient, so it reads as a different kind of thing rather than less of the same thing.
- The letter markers are filled blocks in the same shapes the row controls use; a stream silenced
  by someone else's solo now says so with its own `M`; the fold-down caption and the soloed
  channels' labels are blocked in the solo colour. Text on each picks black or white by luminance,
  so a themed solo colour stays readable.
- The row level bars follow the same rule in both windows, so a muted row looks muted wherever
  you are looking.


## 0.11

### Added
- **Double-click the `dBFS max` figure to reset it** and start logging a new maximum. The clip
  dot still resets it too.
- **Double-click the loudness block to reset** the integrated and window readings, alongside the
  ⟲ button and ⇧⌘L.
- **The monitor level shows its position as a percentage** beside the slider, in grey. It is a
  linear amplitude control, so 50 % is −6 dB rather than half as loud — the decibel figure, and a
  note when DIM is engaged, are in the tooltip.
- `--selftest --mute` and an input-peak line in its report, which is how the mute behaviour below
  was established.

### Notes
- **What mute does, measured:** a muted stream leaves the monitor sum, so it disappears from the
  output, the output meters *and* the loudness readings — mute one of two streams and the LUFS
  figures describe the one that is left. Its input channel meters and row level bar keep running,
  because those are measured on the receive thread upstream of the mix. Solo behaves the same way
  for the streams it silences. This is documented in the README; it is a deliberate reading of
  mute as a programme decision rather than a monitoring one, and it is a small change to reverse
  if the other reading is wanted.


## 0.10

### Fixed
- **Crash in the signal panel.** Seven `SIGABRT`s, all in the AppKit text view introduced in 0.9,
  one of them while raising the master volume off silence. `NSAttributedString.size()` called at
  10–30 Hz from inside `NSView.draw(_:)` throws inside CoreText — reproducible under volume but
  not deterministically, and not caused by the glyphs, the font derivation or the paragraph style
  (each tested and ruled out). The view is gone; hand-drawing text in a hot path is not a safe
  trade for the CPU it saves. The meters stay in AppKit: they draw shapes, not text.

### Changed
- **The master figure is now a maximum rather than a live level** — the highest output level since
  it was last reset, labelled `dBFS max`. The bars already show the level, so the number is
  better spent on how hot it got; and because a maximum only changes when a new peak beats the
  old one, it does not need redrawing at all. Click it (or the clip dot) to reset both.
- **The readouts are published on their own observable object**, updated from the existing 0.25 s
  tick and **only when the formatted text changes**. That is the way out of the bind between
  publishing on `AppState` (which re-evaluates every view in the window) and drawing
  continuously (which costs the view graph): a change now reaches three labels instead of the window,
  and it fires rarely.
- Removed the now-dead `LoudnessRow`, `StereoMeter`, the slow-falling readout envelope and the
  live `readout` strings.

### Notes
- The rule this arrived at after repeated profiling: a continuously changing
  value should be polled by whatever displays it, or formatted and published on a narrow object
  only when its text changes — never published app-wide, and never hand-drawn to dodge the first
  two.


## 0.9

### Fixed
- **CPU in the reported scenario — ten streams discovered, one joined, Dante on, panel open —
  went from 24–28 % of a core to 8–10 %.** Three more causes on top of 0.8's two, none of them in
  the audio path:
  - **Two more publishes fired by network traffic**: an announcement timestamp stamped
    into the published `streams` array on *every* SAP and RAVENNA announcement, and the Dante
    device list assigned unconditionally each time the browser re-reported it. Neither is
    displayed. `--selftest` now prints a **publishes per second** figure, since this is the third
    time this bug has appeared.
  - **The two always-visible numeric readouts were still `TimelineView`s** — the dBFS
    figure and the loudness block, at 10 fps. Deleting them took the app from 27.6 % to 12.9 %,
    so they were worth ~15 % of a core between them. `minimumInterval` throttles content updates,
    not invalidation; `.periodic` instead of `.animation` measured no better. Both are AppKit
    now, drawn on their own timer.
  - **The meter refresh rate is now the dominant cost**, because an AppKit redraw
    schedules a Core Animation commit. Default changed from 60 fps to **30**.

### Added
- **Meter refresh** is back in Settings → View (20/30/60 fps). It was removed in 0.7 as a placebo
  after measuring no difference between 60 and 20 — which was true of the all-SwiftUI meters and
  stopped being true once they became AppKit views. The help text carries the measured cost.

### Notes
- Two conclusions from 0.7–0.8 did not survive: that the refresh
  rate did not matter, and a 3.6× cliff between 30 and 60 fps that was over-read from two noisy
  single runs. The slope is roughly linear. Single short samples of this app carry ±3–5 % of
  noise on a busy machine.


## 0.8

### Fixed
- **CPU while receiving: about 30 % of a core down to 4 %**, one 8-channel stream, panel open,
  meters at 60 fps. Two causes, both in the UI and neither where it looked:
  - A `TimelineView` invalidating made AppKit lay out the window's **entire view tree on every
    display cycle** — 120 times a second on a ProMotion display. Every animated meter is
    now an `NSView` that redraws on its own timer and marks only itself, so SwiftUI is not
    involved. Pinning fixed frames around the timelines was tried first and did nothing.
  - The 4 Hz tick **published a packet counter** into state the whole window observes, so the
    window's attribute graph was re-evaluated four times a second. Published per-stream
    state is now just `receiving` / `lost` / `underruns`, which do not change on a healthy
    stream; the figures that climb are polled by the expanded row instead, and only while it is
    expanded.
- **The documented CPU figure is measured rather than claimed**.

### Added
- **Output device buffer size** in Settings → Playout (64…1024 frames), with the **latency budget
  shown live**: requested total, device buffer, render block, per-stream floor, and how much is
  left to absorb jitter. The buffer setting is a total and the device's own buffer is spent first
  — at 512 frames only 2.3 ms of a 15 ms setting was doing any jitter absorbing. Dropping the
  device to 128 frames took a live stream from 28 underruns per 45 s to zero **at the same
  setting**.
- **Per-stream arrival jitter** (RFC 3550 smoothed, plus worst case), the **lowest buffer fill**
  since priming, and drift — so a stream that needs a lot of buffer can be diagnosed instead of
  guessed at. A large worst-case jitter with zero loss is the sender's packet pacing, and every
  receiver on that stream needs the same buffer to cover it.
- `--selftest --devicebuffer N --latency N` and a `Latency` / `Meter tap` line in its report.

### Notes
- In testing, the buffer requirement was **not** clock drift (+26 ppm, well inside the
  correction range), **not** packet loss (zero in 59,680 packets) and **not** CPU starvation
  (fixing the 30 % changed underruns hardly at all). It was 12.3 ms of worst-case arrival jitter
  from the sender, against a device buffer eating most of the budget.


## 0.7

### Changed
- **The master output bars are no longer choppy.** The cause was not the frame rate: the
  metering tap fires at **10 Hz** with 4800-frame blocks however small a buffer is requested, so the old envelope spent 100 ms decaying 6.7 dB between callbacks and was yanked back
  up by the next one. The bars are now a one-pole follower with a 25 ms attack and a 0.30 s
  release, so each measurement is a rise into position rather than a jump and the motion is
  continuous. The dBFS figure and the peak-hold marker keep instant attack, so the true peak is
  still reported — smoothed bar to watch, peak marker to read.
- **The per-channel input meters run at 60 fps** instead of 20. Their data was always smooth —
  it comes off the receive thread once per packet, 1 kHz on a 1 ms stream — so they only ever
  needed sampling more often.
- **Meters are batched into one `Canvas` per row of channels** rather than one view per bar, so sixteen channels cost the same number of clips and gradient layers as one, and
  channel labels no longer re-lay-out at the meter rate. Measured afterwards, the refresh rate is
  below the noise floor: panel visible at 60 fps and at 20 fps both measure ~21 % against ~20.8 %
  with the panel hidden. A "Meter refresh" setting was built for this and then removed, because
  it would have been a control that changes nothing.
- `--selftest` prints the metering tap's real block size and rate, which is how the 10 Hz was
  found rather than guessed at.

### Fixed
- **The documented CPU figures were wrong.** The README claimed roughly 0.5 % with streams
  playing; measured, one 8-channel 48 kHz stream costs about 20 % of a core, with idle at 0.7 %.
  Nearly all of it is the receive path rather than the display, it is unchanged by this release,
  and it has not been profiled — noted as outstanding.


## 0.6

### Added
- **Solo individual channels within a stream.** Open a row's disclosure and every channel is a
  chip — SMPTE names where the layout is known, numbers otherwise — plus one-click **Front**,
  **Sides** and **Rears** groups for the surround layouts. Soloed channels are heard in the
  positions the fold-down gives them and with its trim applied, so a solo is level-matched to the
  same channels inside the full fold-down and can be used for A/B. It overrides the mix mode
  while engaged rather than filtering it, so soloing channel 7 on a row set to `Ch 1/2` makes a
  sound instead of silence. The signal panel dims the channels you have taken out and names the
  ones you have left in.
- **Custom colour scheme**, in Settings → Theme, as an opt-in override on top of light/dark.
  **Window** washes every surface — the list, the toolbar and the signal panel take the hue
  instead of white and off-white, with the panel still a shade apart. **Active** is anything
  switched on: a stream being listened to and its stop button, `ACTIVE`, the panel toggle, MONO
  and the sliders. Five presets and a colour picker each.
  The window colour is a wash *over* the appearance's own background rather than a flat fill,
  which is what preserves the existing shading — every surface is still `Color.primary` at a low
  opacity and still darkens in light mode and lightens in dark mode, just over a tinted ground.
  Meter colours, the RAVENNA/Dante/SAP tints, solo yellow and mute red are deliberately left
  alone: those carry information rather than decoration, and solo has to stay distinct from
  Active. Text on a coloured pill flips between black and white by luminance, and where Active
  is drawn as a glyph rather than a fill it is nudged for legibility without losing the hue.
- `ACTIVE` in the toolbar was still on the system accent rather than the theme; it follows
  **Active** now, like every other switched-on control.
- `--selftest` gained `--solo` (1-based channel list) and `--mixmode` (`downmix`, `pair:N`,
  `mono:N`), and reports the mix and solo state per stream. `--render` also writes
  `ui-theme.png`.

### Changed
- **The output dBFS figure and the peak-hold marker no longer share the bars' ballistic**.
  All three still attack instantly; the releases now differ, because the displays answer
  different questions — bars about 67 dB/s as before, the dBFS figure about 17 dB/s so a number
  sits still long enough to be read, and the peak hold holding for 1.5 s where it was hit before
  sliding down at about 7 dB/s. The hold previously snapped back to the current level after two
  seconds, which read as the marker teleporting rather than falling.

### Notes
- Channel solo is not persisted between launches, and is not in the compact window: no room for
  eight chips at 380 points, and it is a thing you do while looking at a row's detail.
- Loudness targets were already per-reading in Settings → Loudness (short-term, window,
  integrated, with −23 and −14 LUFS presets) since 0.4 — unchanged here.


## 0.5

Renamed to **Network Audio Grabber**, with a new app icon.

> **Upgrading from 0.4:** the bundle identifier is now `app.networkaudiograbber.monitor`, so
> macOS treats this as a new app and **Local Network access must be granted again** — System
> Settings → Privacy & Security → Local Network. Until it is, RAVENNA and Dante discovery
> silently return nothing while SAP keeps working, which looks exactly like a fault in the app. **Settings are carried over automatically** on first launch — interface, favourites,
> insert plugin and its state, loudness targets and window sizes all survive; only the system
> permission cannot be, because macOS keys that off the identifier itself.

### Changed
- Renamed throughout: the app, the bundle, the SwiftPM target (`NetworkAudioGrabber`), the
  window title, the RTSP `User-Agent`, the preference domains and the docs. The binary and
  module keep the spaceless form; the bundle on disk is `Network Audio Grabber.app`.
- **New app icon.** Four level bars at uneven heights, bone on a muted indigo plate — two
  colours, no gradient on the mark, nothing overlapping anything. The previous icon was a
  symmetric waveform in cyan on charcoal, which is what a great many audio apps look like.
  Three other directions were tried and dropped on the way (an RJ45 plug, a bar group crossed by
  a target line, segmented LED ladders); `Tools/make_icon.swift` records what was wrong with
  each, since they are easy to walk back into.

### Added
- One-time **preferences carry-over** from the previous bundle identifier, so the rename does not
  reset every setting. It fills in blanks only, never overwrites, and is skipped for the
  throwaway suites the `--render` and `--selftest` harnesses use.


## 0.4

### Added
- **Compact window**, switchable either way with **⌥⌘C** (also Settings → View, and a button on
  both layouts). The monitor controls, the loudness readings, the inserts and whatever is
  playing, in a 380-point strip; the discovery list folds behind a disclosure. It is a different
  arrangement of the same state, not a reduced-function mode — every control drives exactly what
  its equivalent in the full window drives. Each layout remembers its own window size.
- **Loudness metering to ITU-R BS.1770-4 / EBU R 128**: `LUFS-S` (3 s), `LUFS-W` over a window
  you set from 1 s to 10 minutes, and `LUFS-I` since the last reset. Each has its own target and
  shows the deviation both as a figure in LU and as a dot on a centre-zero bar. Settings →
  Loudness has the window length, the three targets and presets for −23 LUFS (R 128) and
  −14 LUFS (streaming).
- **⇧⌘L resets** the integrated and window readings; there is a ⟲ button on the block too. A new
  **Monitor** menu carries both shortcuts, so they work while another app is in front.
- **Dry/wet balance on every insert**, the way Reaper does it per-FX, alongside a **BYP** that is
  now a real bypass rather than a request to the plugin.
- `Tools/lufs_test.swift` checks the loudness meter against closed-form answers — the
  K-weighting at 48, 44.1 and 96 kHz, both gating passes, reset, and independence from the
  render block size.
- `--selftest` gained `--insert2`, `--mix` and `--silent`, and now prints the audio graph as it
  was actually wired. `--render` also writes `ui-compact.png`.

### Changed
- **Master output bars are fluid rather than stepped.** The tap writes an envelope and a
  timestamp and the meter decays it to the moment of the read, so the fall is continuous in time
  instead of holding still between callbacks; the master bars alone moved to 60 fps. The
  ballistic is unchanged at 20 dB in 300 ms. Input and row meters stay at 20 fps.
- **Insert bypass and dry/wet no longer rebuild the audio graph** — they are gain changes on a
  chain that already exists, so they take effect without stopping the engine. Only loading or
  clearing a plugin rebuilds.
- Insert slots are wired as a parallel dry/wet pair rather than in line, which is what makes
  both of the above true.

### Fixed
- **`--selftest` was writing to the app's real preferences.** It loads a plugin into insert 1 and
  joins streams, and `shutdown()` persists both, so running a diagnostic quietly changed the
  app's settings. It now uses a throwaway suite, as `--render` already did.

### Notes
- Loudness is measured on the summed bus **before** master level, DIM, MONO and the inserts, so
  the monitor knob cannot move a reading and room correction is not counted as programme. Peak
  metering stays post-insert and post-monitor-level. Two questions, two tap points.
- A **partial** dry/wet blend across a plugin that reports latency will comb-filter; there is no
  delay compensation on the dry path. Full wet and full dry are exact, and the log says so the
  first time it matters.


## 0.3

Renamed from **AES67 Monitor**, with an app icon.

> **Upgrading from 0.2:** the bundle identifier changed (it previously carried a
> company-specific prefix), so macOS treats this as a new app. Settings start fresh, and **Local Network access must be granted again** — System
> Settings → Privacy & Security → Local Network. Until it is, RAVENNA and Dante discovery
> silently return nothing while SAP keeps working.

### Added
- **Dante devices are marked `AES67` or `no flow`** in Settings, so a device that is reachable
  but publishing nothing we can receive is obvious. The banner also states that Dante Virtual
  Soundcard and Dante Via cannot produce AES67 flows at all.
- **Signal panel** down the right-hand side, reading the monitor path top to bottom: incoming
  channel meters per stream, then the two insert slots, then the master output. Master volume,
  DIM, MONO, the dB readout and the clip indicator now live here. Toggle it from the toolbar.
- **Per-channel input meters**, sized for any channel count — 2, 6, 8, or 64, which wraps into
  rows of sixteen. Labelled with SMPTE names when a stream is folded down, numbers otherwise.
- **Mute, solo and level on every active row**, always visible rather than behind the
  disclosure arrow. Only the diagnostic figures fold away now.
- **Auto-rejoin**: streams you were listening to are rejoined when they are next announced.
- **Local Network diagnostic**: if Bonjour returns nothing for 20 s while it is enabled, the log
  says so and points at the privacy setting, instead of looking like a fault in the app.
- Generated app icon (`Tools/make_icon.swift`, run automatically by `build.sh`).

### Changed
- **Meters are far more responsive.** They were updating about three times a second; they now
  refresh at 20 fps and fall with a 200 ms ballistic.
- Meter colours are keyed to level rather than bar position: green to −18 dBFS, amber to −6,
  red above. A healthy −18 dBFS signal used to look like it was clipping.
- Input levels are measured per channel on the receive thread, so they no longer depend on
  which fold-down is selected.
- Idle CPU went from about 16 % to **0 %**; about 0.5 % with streams playing.
- Channel-count chips read "8 ch" rather than an inferred "7.1", and channel pairs read
  "Ch 1/2" rather than "L/R" — the SMPTE assumption stays visible instead of implied.
- Everything identifying this workplace was removed: sample data, addresses, device names and
  the bundle identifier are all generic.

### Fixed
- `DanteBrowser` and `RavennaBrowser` cleared their state asynchronously in `stop()`, which
  could land *after* the browser's first batch of results. Because `NWBrowser` only reports
  changes, anything already found was then never announced again and the list stayed empty.
- Dante device addresses often never resolved, so streams from Dante senders went untagged.
- Auto-rejoin dropped still-pending streams when it rejoined only some of them.
- The preview harness wrote its synthetic favourites into the real app's preferences.
- `--selftest` had stopped printing the activity log.
- The window title still read "AES67 Monitor" after the rename.
- The Dante device count in the log never updated past the first device found.
- Source labels could flip between `DANTE` and `RAVENNA` on refresh, because whichever
  discovery mechanism reported last won. Labels now follow a fixed precedence.

## 0.2

### Added
- SMPTE fold-down of 4.0 / 5.1 / 7.1 streams to stereo, ITU-R BS.775 coefficients, with a
  downmix trim and optional LFE.
- Dante device discovery and stream tagging.
- Two Audio Unit insert slots with bypass, editor windows and state saved between launches.
- DIM, MONO, per-stream solo, favourites, search, active-only filter, light/dark/system.
- Headphone safety limiter (off by default).
- `--selftest` and `--render` development harnesses.

### Fixed
- Scanning `kAudioUnitType_MusicEffect` deadlocks whenever an `AVAudioEngine` is running, which
  left the insert menus permanently empty.
- The playout target could be smaller than one CoreAudio render block, causing permanent
  underrun on devices with larger buffers.

## 0.1

First working version: SAP and RAVENNA discovery, RTP L16/L24/L32 receive, adaptive drift
compensation, CoreAudio output following the default device, `--probe` diagnostics and a fake
sender for hardware-free testing.

### Fixed
- Swift treats `\r\n` as a single `Character`, so splitting SDP on `"\n"` or `"\r"` matched
  nothing and every session failed to parse, silently.
