#!/usr/bin/env python3
"""A fake internet radio station on this Mac, for testing the Grabber's internet streams.

    afconvert -f adts -d aac -b 128000 tone.wav tone.aac      # make test files with macOS's own
    afconvert -f flac -d flac tone.wav tone.flac               # encoder, from any WAV
    ./web_stream_server.py --aac tone.aac --flac tone.flac     # serves on 127.0.0.1:8765 only

Paths: /aac (HTTP 200, ICY titles every 8192 bytes), /icy (the same, answering "ICY 200 OK" as
SHOUTcast does), /flac (no metadata), /redirect (302 to /aac), /list.m3u and /list.pls
(playlists pointing at /aac), /hls.m3u8 (an HLS playlist, to be refused), /page (a web page),
/ogg (an Ogg stream, to be refused), anything else 404. Audio is paced at its real bitrate after
a short burst, as a real server does. Written from the ICY conventions; no server code is used.
"""
import argparse, os, socketserver, threading, time

HOST, PORT = "127.0.0.1", 8765
META_INTERVAL = 8192


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--aac", required=True)
    p.add_argument("--flac")
    p.add_argument("--seconds", type=float, default=0, help="stop after this long (0 = until Ctrl-C)")
    p.add_argument("--audio-seconds", type=float, default=30, help="how long the audio files are")
    a = p.parse_args()
    files = {"aac": open(a.aac, "rb").read(), "flac": open(a.flac, "rb").read() if a.flac else b""}

    def metadata(title):
        text = f"StreamTitle='{title}';".encode()
        text += b"\0" * (-len(text) % 16)
        return bytes([len(text) // 16]) + text

    class Handler(socketserver.StreamRequestHandler):
        def send_head(self, status, headers):
            head = status + "\r\n" + "".join(f"{k}: {v}\r\n" for k, v in headers.items()) + "\r\n"
            self.wfile.write(head.encode())

        def stream(self, data, content_type, icy, status="HTTP/1.0 200 OK", loop=True):
            wants_meta = icy and "icy-metadata: 1" in self.request_text.lower()
            headers = {"Content-Type": content_type, "icy-name": "Test Station", "icy-br": "128"}
            if wants_meta:
                headers["icy-metaint"] = str(META_INTERVAL)
            self.send_head(status, headers)
            rate = len(data) / a.audio_seconds            # bytes a second, as the file plays
            start, sent, burst = time.monotonic(), 0, int(rate * 3)
            song, until_meta, pos = 0, META_INTERVAL, 0
            try:
                while True:
                    chunk = data[pos:pos + 1024]
                    if not chunk:
                        if not loop:
                            return
                        pos = 0
                        continue
                    pos += len(chunk)
                    chunk_audio = chunk
                    out = b""
                    while chunk:
                        if wants_meta and until_meta == 0:
                            song_now = int((time.monotonic() - start) // 5)
                            out += metadata(f"Test Artist - Song {song_now + 1}")
                            until_meta = META_INTERVAL
                        take = chunk[:until_meta] if wants_meta else chunk
                        out += take
                        chunk = chunk[len(take):]
                        if wants_meta:
                            until_meta -= len(take)
                    self.wfile.write(out)
                    sent += len(chunk_audio)          # audio bytes only: metadata is extra
                    ahead = (sent - burst) / rate - (time.monotonic() - start)
                    if ahead > 0:
                        time.sleep(ahead)
            except (BrokenPipeError, ConnectionResetError):
                return

        def handle(self):
            lines = []
            while True:
                line = self.rfile.readline(4096)
                if not line or line in (b"\r\n", b"\n"):
                    break
                lines.append(line.decode(errors="replace"))
            self.request_text = "".join(lines)
            path = lines[0].split()[1] if lines and len(lines[0].split()) > 1 else "/"
            if path == "/aac":
                self.stream(files["aac"], "audio/aac", icy=True)
            elif path == "/icy":
                self.stream(files["aac"], "audio/aacp", icy=True, status="ICY 200 OK")
            elif path == "/flac" and files["flac"]:
                self.stream(files["flac"], "audio/flac", icy=False, loop=False)
            elif path == "/redirect":
                self.send_head("HTTP/1.0 302 Found", {"Location": f"http://{HOST}:{PORT}/aac"})
            elif path == "/list.m3u":
                self.send_head("HTTP/1.0 200 OK", {"Content-Type": "audio/x-mpegurl"})
                self.wfile.write(f"#EXTM3U\n#EXTINF:-1,Test Station\nhttp://{HOST}:{PORT}/aac\n".encode())
            elif path == "/list.pls":
                self.send_head("HTTP/1.0 200 OK", {"Content-Type": "audio/x-scpls"})
                self.wfile.write(f"[playlist]\nNumberOfEntries=1\nFile1=http://{HOST}:{PORT}/aac\n".encode())
            elif path == "/hls.m3u8":
                self.send_head("HTTP/1.0 200 OK", {"Content-Type": "application/vnd.apple.mpegurl"})
                self.wfile.write(b"#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10,\nseg1.ts\n")
            elif path == "/page":
                self.send_head("HTTP/1.0 200 OK", {"Content-Type": "text/html"})
                self.wfile.write(b"<html><body>A station's web page</body></html>")
            elif path == "/ogg":
                self.send_head("HTTP/1.0 200 OK", {"Content-Type": "application/ogg"})
                self.wfile.write(b"OggS" + b"\0" * 1000)
            else:
                self.send_head("HTTP/1.0 404 Not Found", {"Content-Type": "text/plain"})

    class Server(socketserver.ThreadingTCPServer):
        allow_reuse_address = True
        daemon_threads = True

    server = Server((HOST, PORT), Handler)
    print(f"Test station on http://{HOST}:{PORT}/aac (and /icy, /flac, /redirect, /list.m3u, /list.pls)")
    if a.seconds:
        threading.Timer(a.seconds, server.shutdown).start()
    server.serve_forever()


if __name__ == "__main__":
    main()
