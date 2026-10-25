"""Local server for trying the map layers in a desktop browser.

    python tools/map-viewer/serve.py --tiles pdf=out/yosemite.mbtiles --tiles terrain=out/yosemite-terrain.mbtiles \
        --pmtiles out/parktiles --static tools/map-viewer 8766

Serves MBTiles at /tiles/<name>/{z}/{x}/{y}.<ext>, PMTiles files at /parktiles/<file> (with HTTP
Range support, which the PMTiles client needs) and static pages from --static. The app's 3D
page lives in android/app/src/main/assets/map3d and can be served with --static too.
"""
import argparse
import http.server
import mimetypes
import os
import re
import sqlite3

TYPES = {"jpg": "image/jpeg", "png": "image/png", "pbf": "application/x-protobuf"}


def make_handler(tilesets, pmtiles_dir, static_dir):
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def send(self, code, body, ctype, extra=()):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            for k, v in extra:
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path = self.path.split("?")[0]
            m = re.match(r"^/tiles/([\w-]+)/(\d+)/(\d+)/(\d+)\.(\w+)$", path)
            if m and m.group(1) in tilesets:
                z, x, y = int(m.group(2)), int(m.group(3)), int(m.group(4))
                row = sqlite3.connect(tilesets[m.group(1)]).execute(
                    "SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=?",
                    (z, x, (1 << z) - 1 - y)).fetchone()
                if not row:
                    return self.send(404, b"", "text/plain")
                headers = [("Content-Encoding", "gzip")] if m.group(5) == "pbf" else []
                return self.send(200, row[0], TYPES.get(m.group(5), "application/octet-stream"), headers)
            if path.startswith("/parktiles/") and pmtiles_dir:
                file = os.path.join(pmtiles_dir, os.path.basename(path))
                if not os.path.exists(file):
                    return self.send(404, b"", "text/plain")
                size = os.path.getsize(file)
                r = re.match(r"bytes=(\d+)-(\d*)", self.headers.get("Range", ""))
                with open(file, "rb") as f:
                    if r:
                        a = int(r.group(1))
                        b = int(r.group(2) or size - 1)
                        f.seek(a)
                        return self.send(206, f.read(b - a + 1), "application/octet-stream",
                                         [("Content-Range", f"bytes {a}-{b}/{size}"), ("Accept-Ranges", "bytes")])
                    return self.send(200, f.read(), "application/octet-stream", [("Accept-Ranges", "bytes")])
            file = os.path.normpath(os.path.join(static_dir, path.lstrip("/") or "index.html"))
            if not file.startswith(os.path.abspath(static_dir)) or not os.path.isfile(file):
                return self.send(404, b"not found", "text/plain")
            with open(file, "rb") as f:
                return self.send(200, f.read(), mimetypes.guess_type(file)[0] or "application/octet-stream")

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("port", type=int, nargs="?", default=8766)
    parser.add_argument("--tiles", action="append", default=[], metavar="NAME=FILE.mbtiles")
    parser.add_argument("--pmtiles", metavar="DIR")
    parser.add_argument("--static", default=os.path.dirname(os.path.abspath(__file__)))
    args = parser.parse_args()
    tilesets = dict(t.split("=", 1) for t in args.tiles)
    handler = make_handler(tilesets, args.pmtiles, os.path.abspath(args.static))
    print(f"http://127.0.0.1:{args.port}/")
    http.server.ThreadingHTTPServer(("127.0.0.1", args.port), handler).serve_forever()


if __name__ == "__main__":
    main()
