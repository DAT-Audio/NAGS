Network Audio Grabber & Sender for Windows - 0.16.2 (beta)
==========================================================

A beta, for trying. Built from the same engine as the Mac apps, so a stream from a
Mac and a stream from this PC are the same stream, and each plays on the other.

New in 0.16.2:
- Gone streams are told apart. A playing stream whose sender has left (no audio for 30 s and
  no announcement either) moves to a folded Gone section under the list, above Ignored. It
  stays joined and plays again if it comes back; left alone it stops after 5 minutes. Stop or
  Clear all clears them sooner, and right-click > Ignore this stream moves one to Ignored.
  In the compact window a gone stream says Gone instead of No packets.
- A renamed Sender keeps playing when its old name came from a broadcast.
- Quiet RAVENNA sessions stay listed: each is asked for its description again every minute,
  and one that says goodbye on Bonjour leaves the list at once.
- A Dante device that leaves the network (says goodbye on Bonjour) is forgotten, instead of
  staying listed until the Grabber is restarted.
- Streams are labelled Dante only when they come from Dante: the label now comes from the
  stream's own announcement. Before, a PC running Dante software beside another maker's AES67
  driver had that driver's streams labelled DANTE (AES67).
- A stream asked for from a Sender keeps playing when the Sender is renamed, and the Grabber
  no longer keeps asking for the old name. The log says "this computer", not "this Mac".

New in beta 3 (fixes from testing beta 2 against the Mac):
- Findable by Grabbers in the Grabber's Send now works: a Mac Grabber pressing play asks, and
  the PC shows Allow. (The Send's offer never started, so no announcement left the PC.)
- The Grabber no longer lists its own Send when that Send broadcasts on a network it listens on.
- The highlight colour is back: playing streams, toggles, the selected Settings page and the
  header menus use Windows' accent colour, or the Mac's orange where the accent is grey.
- Closer to the Mac's layout: the output name cut at its end, a small Receive / Send switch in
  the compact window, the house icon on LOCAL, bold names on playing streams, a chevron on the
  output menu, the Connect guide's heading; in the Sender, the source shown once (in the
  toolbar), labelled channel meters and LOCAL on receivers.
- Dante devices is on by default, as on the Mac, so Dante streams are labelled Dante. An SAP
  stream says how to label it when Dante devices is off.
- nag-grab --list --dante-txt prints what each Dante device publishes about itself (maker,
  model), the first step towards recognising Focusrite RedNet units.

New in beta 2: the Grabber's window is now the Mac's - the full window with its source sidebar,
columns and signal panel, the compact window, every Settings pane, the Connect / Send window,
VST3 inserts, colour schemes and looks, all three loudness readings with a pinned one, the level
history, a choice of output device, RAVENNA and Dante found over Windows' own Bonjour, and
surround buses that work on headphones with Windows Sonic or Dolby Atmos for Headphones.

Five programs, two apps:

    nag-grabber.exe    the Grabber, with a window. Plays network audio on this PC.
    nag-grab.exe       the same Grabber without a window, for a terminal.
    nag-sender.exe     the Sender, with a window. Sends this PC's audio to a Grabber.
    nag-send.exe       the same Sender without a window.
    nag-vst3-scan.exe  used by the Grabber to look at VST3 plug-ins safely. Not opened by hand.

    QUICK-START.html   the quick-start guide (written for the Mac; the words and layout match)
    Licences\          the licences of everything inside


Getting started
---------------

1. Unzip the whole folder somewhere that is not synced (Desktop or Documents is fine; not
   Dropbox or OneDrive). Keep the files together: the DLLs beside the programs are what they
   need to run.

2. Double-click nag-grabber.exe.

3. Windows Defender Firewall will ask whether to let it on the network. Tick **Private
   networks** and choose **Allow access**. Without that, streams from other machines cannot
   reach it. (nag-sender asks the same, the first time it sends.)

4. Streams appear in the list as they are found. Press play on one to hear it.

Nothing plays until you press play, and the Grabber sends nothing on the network unless you
play a stream that needs asking for (a Network Audio Sender), add a Sender by address, use
Send, or have RAVENNA or Dante browsing on (Settings > Discovery; both are on, as on the Mac).


The Grabber window
------------------

It is the Mac Grabber's layout and wording:

  Toolbar       the network AES67 is received on, the output device and its rate (click either
                to change), and on the right the source sidebar, the signal panel, the compact
                window, and Settings.
  Sources       All streams, or only one kind: RAVENNA, Dante (AES67), AES67 (SAP), VBAN...
  Receive       the list (drag the edge of the Stream column in the titles to give names more room;
                the signal panel and sidebar make way, and their own edges drag too):
                play/stop, star, the stream's level on every channel, its bus (mix)
                menu, trim, M and S, the source and channel count, and the status. Press a
                playing stream's name or its chevron to open it: per-channel meters, the mix,
                channel solo (with Front / Sides / Rears), and in Detailed view (Settings > View)
                jitter, buffer, drift, lost packets and underruns. Right-click a stream to copy
                its SDP or address, or to ignore it.
  Send          along the bottom: this PC's audio sent to other receivers (see below).
  Signal panel  Inserts (three VST3 slots), then the Output: dBFS max with the clip dot, the
                Loudness readings - short-term, window and integrated against their targets,
                the pinned one first and larger - the meters with their scale, the bus menu,
                volume, DIM, MONO and the last 30 seconds of level.
  Compact       the same controls in a narrow strip, with Receive / Send tabs.

Tooltips say what each control does and what it is doing now. Any slider goes back to its
default on a double-click. Ctrl+, opens Settings; Ctrl+Shift+L resets the loudness.


Surround on headphones (Windows Sonic, Dolby Atmos for Headphones)
-----------------------------------------------------------------

Choose 7.1 as the bus (beside the meters, or Settings > Output). The Grabber hands Windows a
properly labelled 7.1 stream, and with spatial sound on Windows places it around your head: the
rears behind, the sides beside. This works even though headphones are a two-channel device.
Beta 1 offered only Stereo on such a device; that is fixed. Leave the bus on Stereo and surround
streams are folded down first.


Output device
-------------

The toolbar's device name, or Settings > Output: the system default (following Windows), or a
named device that stays chosen whatever Windows' setting is. Unplug it and the Grabber plays on
the default until it is back, and says so.


Inserts
-------

Three VST3 effect slots on the monitor bus, after the loudness measurement and before the
monitor level, as on the Mac. Plug-ins are found in C:\Program Files\Common Files\VST3. Each
slot has BYP (a hard bypass), delta (hear only what the plug-in changes), its own window, and a
dry/wet slider (Settings > View). A plug-in that will not take the bus's width is held out of
circuit and says so, rather than being applied to part of the bus.

Plug-ins are first looked at in a separate process, so one that crashes then cannot take the
Grabber with it; those are left out of the list (Settings > Inserts says how many). Some
copy-protected plug-ins do this on purpose.


Discovery: RAVENNA and Dante
----------------------------

Both are found with Windows' own Bonjour - nothing to install. RAVENNA sessions are listed by
themselves. Dante devices are found too ("Dante devices (AES67 mode)" in Settings > Discovery,
on by default from beta 3, as on the Mac), and their AES67 streams are labelled Dante. With it
off, the same streams are labelled AES67 (SAP): the same streams, announced the same way, just
not recognised as Dante. Settings saved by an earlier beta keep their choice: turn it on once.
A Dante device's audio still arrives only over AES67: turn on AES67 for it in Dante Controller.


Send, and the Connect / Send window
-----------------------------------

The Grabber can send this PC's audio, as the Mac Grabber can: the Send section along the
bottom, or the Send tab of the compact window or of the Connect / Send window. Turn on Findable
by Grabbers, add a receiver with +, or Broadcast to a network. It sends everything the PC plays
- including what this Grabber is playing, so don't send to a Grabber whose stream you are also
playing here.

Connect / Send... on the list bar opens the guide: On this network (the steps for a Network
Audio Sender, ticked off as they happen) or Somewhere else (the Remote link, a VPN, or by
address).


What it does not do yet
-----------------------

Internet radio; the Remote link has not been tried between a PC and a Mac yet; height channels
(7.1.2, 7.1.4). The window's text cannot be read by a screen reader yet.


nag-grab - the Grabber without a window
---------------------------------------

Open a terminal in this folder:

    nag-grab --list                      what it can find, for five seconds
    nag-grab --list --dante-txt          the same, and what each Dante device says about itself
    nag-grab --play "Studio A"           play a stream by name (or the start of its name)
    nag-grab --play all --bus 8          everything, on a 7.1 bus
    nag-grab --help                      every option


The Sender
----------

nag-sender.exe is now laid out like the Mac Sender, and built on the same window code as the
Grabber: the stream's name and level, the source, anyone asking to listen (Allow / Deny),
everyone receiving (Findable by Grabbers, Broadcast..., + to add an address; right-click or ...
on a row to pin, mute, rename or remove it), VST3 inserts on what is sent, and a status line
with Connect... and Stop all. Settings has the stream, quality (24-bit unless changed),
channels, the Grabbers you have allowed or denied, auto-stop, the theme, and a Log tab.

Source - what is sent:
  System audio   everything this PC plays, except Network Audio Grabber - so a PC running both
                 does not send the Grabber's playback straight back out. (The Grabber's own Send
                 leaves out the Grabber the same way.)
  One app        only that app's sound. While it is not running, receivers hear silence and
                 stay connected; it is picked up as soon as it starts.
  An input       a microphone or an interface's inputs, whole, at the device's own channels.

nag-send.exe is the same Sender without a window: nag-send --list-sources shows the apps and
inputs, and --source system|app:<exe>|input:<name> picks one. nag-send --help lists the rest.

Fixed: Channels: Stereo always sent two channels; the status line wrongly said otherwise.


Testing it with a Mac
---------------------

  Mac Sender to this Grabber, stereo:  on the Mac Sender turn on Findable by Grabbers. The
      stream appears in nag-grabber. Press play; allow it on the Mac when it asks.
  The same, 7.1:  on the Mac Sender pick an eight-channel output to capture, set the Grabber's
      bus to 7.1, and with Windows Sonic or Dolby Atmos for Headphones on, check the rears come
      from behind and the sides from beside.
  Dante:  with Dante devices on (Settings > Discovery), the Dante streams the Mac labels
      should be labelled Dante here too.
  If the beacon does not reach this PC (another subnet, a VPN): Add a Sender, and type the
      Mac's address.


Where things are kept
---------------------

Settings are kept per Windows user. The Grabber's log and its list of VST3 plug-ins are in
%LOCALAPPDATA%\Network Audio Grabber. Nothing is written beside the programs.


Moving this folder
------------------

Copy the whole folder and it runs on another Windows 10 or 11 PC that has the Microsoft Visual
C++ runtime (VCRUNTIME140.dll), which nearly all do.

