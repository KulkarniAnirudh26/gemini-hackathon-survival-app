"""Local prototype server: PDF raster tiles from MBTiles, NPS Park Tiles PMTiles (with HTTP
Range support, which the PMTiles client needs), and a MapLibre page combining them."""
import http.server, os, re, sqlite3, sys
mbtiles, pmtiles_dir, page, port = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, body, ctype, extra=()):
        self.send_response(code); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(body)))
        for k, v in extra: self.send_header(k, v)
        self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        if self.path.startswith("/tiles/"):
            z, x, y = (int(v) for v in self.path[7:].split(".")[0].split("/"))
            row = sqlite3.connect(mbtiles).execute("SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=?", (z, x, (1 << z) - 1 - y)).fetchone()
            return self.send(200, row[0], "image/jpeg") if row else self.send(404, b"", "text/plain")
        if self.path.startswith("/parktiles/"):
            path = os.path.join(pmtiles_dir, os.path.basename(self.path))
            size = os.path.getsize(path)
            m = re.match(r"bytes=(\d+)-(\d*)", self.headers.get("Range", ""))
            with open(path, "rb") as f:
                if m:
                    a = int(m.group(1)); b = int(m.group(2) or size - 1); f.seek(a); body = f.read(b - a + 1)
                    return self.send(206, body, "application/octet-stream", [("Content-Range", f"bytes {a}-{b}/{size}"), ("Accept-Ranges", "bytes")])
                return self.send(200, f.read(), "application/octet-stream", [("Accept-Ranges", "bytes")])
        return self.send(200, open(page, "rb").read(), "text/html")
http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
