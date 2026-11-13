#!/bin/zsh
# Starts Network Audio Grabber, Network Audio Sender and the DAT Audio plugins afresh, as for a
# new user: every setting, favourite, saved target, link and log they keep on this Mac is removed.
# A copy of everything is kept first, so it can be put back.
#
#   Tools/reset-prefs.sh                 # back up, then reset (asks first)
#   Tools/reset-prefs.sh --dry-run       # only list what would go
#   Tools/reset-prefs.sh --yes           # no question (scripts)
#   Tools/reset-prefs.sh --permissions   # also forget the audio-recording permission
#   Tools/reset-prefs.sh --backup DIR    # keep the copy in DIR (default: the Desktop)
#
# To put a backup back: quit the apps, then
#   cp "<backup>/Preferences/"*.plist ~/Library/Preferences/
#   cp -R "<backup>/Application Support/"* ~/Library/Application\ Support/
#   killall cfprefsd      # so macOS re-reads the restored preferences
#
# Nothing here touches anything that is not these apps'. The Local Network permission cannot be
# reset by command: System Settings → Privacy & Security → Local Network.

set -u
dry=0; yes=0; perms=0
backup="$HOME/Desktop/Network Audio settings backup $(date +%Y-%m-%d\ %H.%M)"
while (( $# )); do
  case "$1" in
    --dry-run) dry=1 ;;
    --yes) yes=1 ;;
    --permissions) perms=1 ;;
    --backup) shift; backup="$1" ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)"; exit 2 ;;
  esac
  shift
done

prefs="$HOME/Library/Preferences"
support="$HOME/Library/Application Support"
saved="$HOME/Library/Saved Application State"

# Every preferences domain the apps, their Send, the plugins (and each open plugin's own),
# and their self-tests use.
setopt null_glob
domains=()
for f in "$prefs"/app.networkaudiograbber.*.plist "$prefs"/app.networkaudiograbber.plist \
         "$prefs"/app.networkaudiosender.*.plist "$prefs"/NetworkAudioGrabber.plist "$prefs"/NetworkAudioSender.plist; do
  [[ -e "$f" ]] && domains+=("${${f:t}%.plist}")
done
folders=()
for d in "$support"/"Network Audio" "$support"/app.networkaudiograbber.* "$support"/app.networkaudiosender.* \
         "$saved"/app.networkaudiograbber.*.savedState "$saved"/app.networkaudiosender.*.savedState; do
  [[ -e "$d" ]] && folders+=("$d")
done

if (( ${#domains} == 0 && ${#folders} == 0 )); then
  echo "Nothing to reset: the apps keep nothing on this Mac yet."
  exit 0
fi

echo "Preferences (${#domains}):"; for d in $domains; do echo "  $d"; done
echo "Folders (${#folders}):";     for d in $folders; do echo "  ${d/#$HOME/~}"; done
(( perms )) && echo "Permission: System Audio Recording for both apps"
(( dry )) && { echo "(dry run: nothing changed)"; exit 0; }

# The apps, and any DAW with a plugin open, must not be running: they would write it all back.
running=$(pgrep -fl "Network Audio Grabber.app/Contents/MacOS|Network Audio Sender.app/Contents/MacOS" || true)
if [[ -n "$running" ]]; then
  echo "\nQuit Network Audio Grabber and Network Audio Sender first."
  exit 1
fi
echo "\nIf a DAW has a DAT Audio plugin open, close that project (or quit the DAW) first."

if (( ! yes )); then
  read "answer?Back up to \"${backup/#$HOME/~}\" and reset? [y/N] "
  [[ "$answer" == [yY]* ]] || { echo "Nothing changed."; exit 0; }
fi

mkdir -p "$backup/Preferences" "$backup/Application Support" || exit 1
for d in $domains; do cp -p "$prefs/$d.plist" "$backup/Preferences/" 2>/dev/null; done
for d in $folders; do cp -Rp "$d" "$backup/Application Support/" 2>/dev/null; done
echo "Backed up to ${backup/#$HOME/~}"

for d in $domains; do
  defaults delete "$d" >/dev/null 2>&1           # through cfprefsd, so nothing stale lingers
  rm -f "$prefs/$d.plist"
done
for d in $folders; do rm -rf "$d"; done

if (( perms )); then
  tccutil reset AudioCapture app.networkaudiosender.send >/dev/null 2>&1
  tccutil reset AudioCapture app.networkaudiograbber.monitor >/dev/null 2>&1
  echo "Audio-recording permission forgotten: macOS asks again on the next send."
fi

echo "Reset. The apps open as for a new user."
