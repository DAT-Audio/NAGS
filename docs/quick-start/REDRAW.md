# Redrawing the quick-start pictures

Pictures are drawn by the apps themselves, with made-up names and example addresses. To
redraw them after a change (the mark positions are in `annotations.json`):

```sh
swift build
.build/debug/NetworkAudioGrabber --guide-shots /tmp/guide        # g*.png
.build/debug/NetworkAudioSender --render /tmp/guide-s            # then copy into /tmp/guide:
#   sender-empty-tall.png → s1-fresh.png, sender-dark.png → s2-findable-allow.png,
#   sender-broadcast-sheet-dark.png → s3-broadcast.png, sender-settings-denied-dark.png → s5-settings-denied.png
swift Tools/annotate-guide.swift docs/quick-start/annotations.json /tmp/guide docs/quick-start/images
python3 Tools/guide-to-html.py        # QUICK-START.html, pictures built in
```
