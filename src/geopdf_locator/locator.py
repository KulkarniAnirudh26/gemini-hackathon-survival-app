"""Find place-name labels on a GeoPDF map, snap them to their map symbol, and rank the hits."""
from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass, field

import pymupdf

from .georef import Georeference

Rect = tuple[float, float, float, float]

# Regions of known maps that are not geographic (legend, notes), keyed by the PDF /Title.
KNOWN_EXCLUSIONS: dict[str, list[Rect]] = {
    "YOSE_ParkMap": [(45, 938, 256, 1216)],
}

# A label "owns" a symbol only if the symbol is this close to the label's bounding box,
# measured in multiples of the label's font size.
SNAP_DISTANCE_EM = 1.6
# Same-style text this close to a match means the match is part of a longer label
# ("Glacier Point" inside "Glacier Point Road"), in multiples of font size.
PHRASE_GAP_EM = 0.6
# Two lines of one name touch or nearly touch (normal leading; letter-spaced caps like
# "SIERRA / NATIONAL / FOREST" run ~0.35 em); separate stacked names sit further apart
# ("Mount Maclure" over "Mount Lyell": 0.53 em).
STACK_GAP_EM = 0.4
# Point symbols are small, roughly square, filled, and not lake-blue/white.
SYMBOL_MAX_SIZE = 12.0
SYMBOL_MIN_SIZE = 0.8
# Locator dots (the exact spot a leader line points to) are the smallest symbols.
DOT_MAX_SIZE = 4.5  # peak dots ~1-2 pt, town dots ~4 pt; icons are ~10 pt
# Leader lines: thin black strokes from a label or icon to a locator dot.
LEADER_MAX_WIDTH = 0.6
LEADER_MAX_LENGTH = 80.0
LEADER_TOUCH = 2.5  # how close a leader end must be to the label/icon/dot it connects
ELEVATION = re.compile(r"^\s*[\d,.]+\s*(ft|m|feet|meters)\s*$", re.I)


@dataclass
class Char:
    text: str  # normalized: lowercase ascii letters/digits (may be "" or several, e.g. "ﬁ" -> "fi")
    raw: str
    bbox: Rect
    style: tuple  # (font, rounded size, color)
    size: float
    block: int = -1  # PDF text block (layout grouping; not reliably one name)
    line: int = -1  # text line, numbered across the whole page in reading order
    fragment: bool = False  # block holds only a glyph or two, i.e. a piece of curved text
    short: bool = False  # one short line: possibly a piece of a curved label ("Glac" / "ier P")
    elevation: bool = False  # part of an elevation note like "8836 ft"


@dataclass
class Symbol:
    bbox: Rect
    owner: int | None = field(default=None, repr=False, compare=False)  # cached nearest char index

    @property
    def center(self) -> tuple[float, float]:
        x0, y0, x1, y1 = self.bbox
        return (x0 + x1) / 2, (y0 + y1) / 2

    @property
    def is_dot(self) -> bool:
        x0, y0, x1, y1 = self.bbox
        return max(x1 - x0, y1 - y0) <= DOT_MAX_SIZE


@dataclass
class Hit:
    query: str
    label: str  # the full label the match belongs to, e.g. "Glacier Point Road"
    lat: float
    lon: float
    page_xy: tuple[float, float]  # where the coordinates were taken from (symbol or label centre)
    label_bbox: Rect
    font_size: float
    standalone: bool  # the label is exactly the query, not part of a longer phrase
    symbol: Symbol | None  # the map symbol the label was snapped to, if any
    via_leader: bool = False  # the symbol was reached by following a leader line
    score: float = field(default=0.0)

    @property
    def snapped(self) -> bool:
        return self.symbol is not None


def normalize(text: str) -> str:
    text = unicodedata.normalize("NFKD", text)  # also splits ligatures like "ﬁ"
    return re.sub(r"[^a-z0-9]", "", text.lower())


def _union(rects) -> Rect:
    xs0, ys0, xs1, ys1 = zip(*rects)
    return min(xs0), min(ys0), max(xs1), max(ys1)


def _gap(a: Rect, b: Rect) -> float:
    """Distance between two rectangles (0 if they overlap)."""
    dx = max(a[0] - b[2], b[0] - a[2], 0)
    dy = max(a[1] - b[3], b[1] - a[3], 0)
    return (dx * dx + dy * dy) ** 0.5


def _point_gap(p: tuple[float, float], r: Rect) -> float:
    return _gap((p[0], p[1], p[0], p[1]), r)


def _inside(rect: Rect, regions: list[Rect]) -> bool:
    cx, cy = (rect[0] + rect[2]) / 2, (rect[1] + rect[3]) / 2
    return any(x0 <= cx <= x1 and y0 <= cy <= y1 for x0, y0, x1, y1 in regions)


def _is_area_label(raw_chars) -> bool:
    """All-caps labels ("TUOLUMNE MEADOWS", "JACK MAIN CANYON") name areas by cartographic
    convention, so their centre is a better location than any nearby point symbol."""
    letters = [c for c in raw_chars if c.isalpha()]
    return len(letters) >= 4 and all(c.isupper() for c in letters)


def _is_symbol_fill(rgb) -> bool:
    r, g, b = rgb
    lum = 0.299 * r + 0.587 * g + 0.114 * b
    sat = (max(rgb) - min(rgb)) / max(rgb) if max(rgb) else 0
    # dark marks (dots, icon squares) or saturated ones (yellow town dots); rejects white glyph
    # interiors and pale water/terrain fills
    return lum < 0.7 or sat > 0.5


class GeoPdfMap:
    """A georeferenced PDF map page that can be searched by place name.

    >>> m = GeoPdfMap.open("yosemite.pdf")
    >>> best = m.locate("Half Dome")[0]
    >>> best.lat, best.lon
    """

    def __init__(self, doc: pymupdf.Document, page_number: int = 0, exclude: list[Rect] | None = None):
        self.doc = doc
        self.page = doc[page_number]
        self.georef = Georeference(doc, self.page)
        if exclude is None:
            exclude = KNOWN_EXCLUSIONS.get(doc.metadata.get("title") or "", [])
        self.exclude = list(exclude)
        self.chars = self._read_chars()
        self.drawings = self.page.get_drawings()
        self.symbols = self._read_symbols(self.drawings)
        self.leaders = self._read_leaders(self.drawings)

    @classmethod
    def open(cls, path: str, page_number: int = 0, exclude: list[Rect] | None = None) -> GeoPdfMap:
        return cls(pymupdf.open(path), page_number, exclude)

    def to_latlon(self, x: float, y: float) -> tuple[float, float]:
        return self.georef.to_latlon(x, y)

    def to_page(self, lat: float, lon: float) -> tuple[float, float]:
        return self.georef.to_page(lat, lon)

    # -- indexing --------------------------------------------------------------------------

    def _read_chars(self) -> list[Char]:
        """All characters in reading order. Curved labels come out one glyph per span, so we
        search a character stream rather than words."""
        chars = []
        line_no = 0
        for block in self.page.get_text("rawdict")["blocks"]:
            start = len(chars)
            for line in block.get("lines", []):
                for span in line["spans"]:
                    style = (span["font"], round(span["size"], 1), span["color"])
                    elevation = bool(ELEVATION.match("".join(c["c"] for c in span["chars"])))
                    for c in span["chars"]:
                        chars.append(
                            Char(normalize(c["c"]), c["c"], tuple(c["bbox"]), style, span["size"],
                                 block["number"], line_no, elevation=elevation)
                        )
                # line break acts as whitespace when rebuilding label text
                chars.append(Char("", "\n", (0, 0, 0, 0), (), 0, block["number"], line_no))
                line_no += 1
            letters = [c for c in chars[start:] if c.text]
            n_letters = sum(len(c.text) for c in letters)
            n_lines = sum(c.raw == "\n" for c in chars[start:])
            for c in chars[start:]:
                c.fragment = n_letters <= 3
                c.short = n_lines == 1 and n_letters <= 6
        self.stacked = self._stacked_lines(chars)
        return chars

    @staticmethod
    def _stacked_lines(chars: list[Char]) -> set[frozenset[int]]:
        """Pairs of consecutive lines that are two lines of one name ("Clouds" / "Rest").

        Lines of one name sit at normal leading, so their boxes touch or overlap; separate
        names stacked near each other ("Mount Maclure" over "Mount Lyell") leave a visible gap.
        Works on lines rather than PDF blocks, which group text by layout, not by name.
        """
        lines: dict[int, list] = {}
        for c in chars:
            if c.text:
                info = lines.setdefault(c.line, [c.bbox, c.style, c.size])
                info[0] = _union([info[0], c.bbox])
        pairs = set()
        for n, (box, style, size) in lines.items():
            nxt = lines.get(n + 1)
            if not nxt or nxt[1] != style:
                continue
            upper, lower = (box, nxt[0]) if box[1] <= nxt[0][1] else (nxt[0], box)
            vgap = lower[1] - upper[3]
            overlap = min(upper[2], lower[2]) - max(upper[0], lower[0])
            if -0.6 * size <= vgap <= STACK_GAP_EM * size and overlap > 0:
                pairs.add(frozenset((n, n + 1)))
        return pairs

    def _read_symbols(self, drawings) -> list[Symbol]:
        """Small filled marks (peak dots, town dots, facility icons). Overlapping layers of one
        icon are merged into a single symbol."""
        rects = []
        for d in drawings:
            r, fill = d["rect"], d.get("fill")
            if fill is None or not _is_symbol_fill(fill):
                continue
            w, h = r.width, r.height
            if not (SYMBOL_MIN_SIZE <= max(w, h) <= SYMBOL_MAX_SIZE) or min(w, h) < 0.6 * max(w, h):
                continue
            rect = (r.x0, r.y0, r.x1, r.y1)
            if not _inside(rect, self.exclude):
                rects.append(rect)

        merged: list[Rect] = []
        for rect in sorted(rects, key=lambda r: -(r[2] - r[0])):  # big icon backgrounds first
            for i, m in enumerate(merged):
                if _gap(rect, m) == 0:
                    merged[i] = _union([m, rect])
                    break
            else:
                merged.append(rect)
        return [Symbol(r) for r in merged]

    def _read_leaders(self, drawings) -> list[tuple[tuple[float, float], tuple[float, float]]]:
        """Endpoints of leader lines: short, thin, black, straight (1-2 segment) strokes."""
        leaders = []
        for d in drawings:
            items = d["items"]
            if d["type"] != "s" or not items or len(items) > 2 or any(it[0] != "l" for it in items):
                continue
            color, width = d.get("color"), d.get("width") or 0
            if color is None or max(color) > 0.15 or width > LEADER_MAX_WIDTH:
                continue
            a, b = items[0][1], items[-1][2]
            if 2.0 < abs(b - a) <= LEADER_MAX_LENGTH:
                leaders.append(((a.x, a.y), (b.x, b.y)))
        return leaders

    def _follow_leader(self, rect: Rect) -> Symbol | None:
        """If a leader line starts at `rect`, return the locator dot at its other end."""
        best, best_gap = None, LEADER_TOUCH
        for a, b in self.leaders:
            for near, far in ((a, b), (b, a)):
                g = _point_gap(near, rect)
                if g > best_gap or _point_gap(far, rect) <= LEADER_TOUCH:
                    continue
                dot = min(
                    (s for s in self.symbols if s.is_dot and _point_gap(far, s.bbox) <= LEADER_TOUCH),
                    key=lambda s: _point_gap(far, s.bbox),
                    default=None,
                )
                if dot:
                    best, best_gap = dot, g
        return best

    # -- search ----------------------------------------------------------------------------

    def _matches(self, query: str):
        """Yield lists of char indices whose normalized text spells the query."""
        q = normalize(query)
        if not q:
            return
        stream, owner = [], []
        for i, c in enumerate(self.chars):
            for ch in c.text:
                stream.append(ch)
                owner.append(i)
        text = "".join(stream)
        for m in re.finditer(re.escape(q), text):
            yield sorted(set(owner[m.start() : m.end()]))

    def _grow_label(self, indices: list[int]) -> list[int]:
        """Extend a match with nearby same-style characters to recover the whole label.

        A label is one line, consecutive lines stacked at normal leading ("Badger / Pass Ski
        Area", "Clouds" / "Rest"), or a chain of small blocks along a curve. Separate labels
        stacked with a gap ("Mount Maclure" above "Mount Lyell") are not merged.
        """
        first = self.chars[indices[0]]
        limit = PHRASE_GAP_EM * first.size
        label = set(indices)
        # spaces count too, so a curved run like "Wawona   Road" stays one label
        candidates = {
            i for i, c in enumerate(self.chars)
            if c.style == first.style and (c.text or c.raw == " ") and i not in label
        }

        stacked = self.stacked

        def joinable(a: Char, b: Char) -> bool:
            linked = (
                a.line == b.line
                or frozenset((a.line, b.line)) in stacked
                # curved labels are written out a few glyphs per block
                or a.fragment or b.fragment
                or (a.short and b.short and abs(a.block - b.block) == 1)
            )
            return linked and _gap(a.bbox, b.bbox) <= limit

        frontier = list(indices)
        while frontier and len(label) < 80:
            added = [i for i in candidates if any(joinable(self.chars[i], self.chars[j]) for j in frontier)]
            candidates.difference_update(added)
            label.update(added)
            frontier = added
        return sorted(label)

    def _label_text(self, indices: list[int]) -> str:
        """Rebuild label text, finding word breaks from letter spacing rather than from the
        PDF's spaces and line breaks, which curved and letter-spaced labels don't use reliably."""
        lines = {self.chars[i].line for i in indices}
        if len(lines) > 1 and not any(self.chars[i].fragment for i in indices):
            # a name stacked over several lines reads top to bottom
            top = {n: min((self.chars[i].bbox[1], self.chars[i].bbox[0]) for i in indices
                          if self.chars[i].line == n) for n in lines}
            indices = sorted(indices, key=lambda i: (top[self.chars[i].line], i))
        letters = [i for i in indices if self.chars[i].text]
        size = self.chars[letters[0]].size if letters else 0

        def centre(c: Char) -> tuple[float, float]:
            return (c.bbox[0] + c.bbox[2]) / 2, (c.bbox[1] + c.bbox[3]) / 2

        def step(a: Char, b: Char) -> float:
            (ax, ay), (bx, by) = centre(a), centre(b)
            return ((bx - ax) ** 2 + (by - ay) ** 2) ** 0.5

        def spaced_between(a: int, b: int) -> bool:
            return b > a and any(c.raw.isspace() and c.raw != "\n" for c in self.chars[a + 1 : b])

        # Word breaks, by kind of label (centre distances are used because the boxes of rotated
        # letters overlap):
        #  - letter-spaced caps ("T U O L U M N E", maybe with a space glyph after every letter):
        #    a step clearly longer than the label's own letter spacing
        #  - curved labels, written a few glyphs per block: a space glyph that also widens the
        #    step (stray spaces end some pieces mid-word), or a jump far beyond the letter spacing
        #  - everything else: spaces and line changes
        pairs = list(zip(letters, letters[1:]))
        steps = sorted(step(self.chars[a], self.chars[b]) for a, b in pairs)
        median = steps[len(steps) // 2] if steps else 0
        curved = len({self.chars[i].block for i in letters}) > 1 and any(
            self.chars[i].fragment or self.chars[i].short for i in letters)
        mostly_spaced = bool(pairs) and sum(spaced_between(a, b) for a, b in pairs) > len(pairs) / 2
        letter_spaced = len(letters) >= 4 and (mostly_spaced or (median > 0.85 * size and not curved))

        out, prev = [], None
        for i in letters:
            if prev is not None:
                a, b = self.chars[prev], self.chars[i]
                # a stacked line starts below and to the left (curved text running downhill
                # can look the same, so only straight labels wrap)
                wrapped = (not curved and a.line != b.line
                           and b.bbox[0] < a.bbox[0] and b.bbox[1] >= a.bbox[3] - 0.3 * b.size)
                has_space = spaced_between(prev, i)
                s = step(a, b)
                if letter_spaced:
                    brk = wrapped or s > 1.5 * median or (has_space and s > 1.2 * median)
                elif curved:
                    brk = s > 2.0 * median or (has_space and s > 1.2 * median)
                else:
                    brk = wrapped or has_space or a.line != b.line
                if brk:
                    out.append(" ")
            out.append(self.chars[i].raw)
            prev = i
        raw = unicodedata.normalize("NFKC", "".join(out))  # "ﬁ" -> "fi"
        return re.sub(r"\s+", " ", raw).strip()

    def _symbol_owner(self, symbol: Symbol) -> int | None:
        """Index of the closest label character to a symbol. Elevation notes ("8836 ft") and
        curved text (roads, rivers, area names) never name a point, so they can't own one."""
        if symbol.owner is None:
            best, best_gap = -1, float("inf")
            for i, c in enumerate(self.chars):
                if c.text and not c.text.isdigit() and not c.elevation and not c.fragment \
                        and not _inside(c.bbox, self.exclude):
                    g = _gap(symbol.bbox, c.bbox)
                    if g < best_gap:
                        best, best_gap = i, g
            symbol.owner = best
        return symbol.owner

    def _snap(self, label_idx: list[int], label_box: Rect, size: float) -> tuple[Symbol | None, bool]:
        """Find the map symbol a label refers to. Returns (symbol, reached_via_leader).

        Order of preference: a leader line drawn from the label to a locator dot; the nearest
        dot that belongs to this label (a town dot beats the amenity icons beside it); the
        nearest icon that belongs to it, or the dot that icon's own leader line points to.
        """
        if _is_area_label(self.chars[i].raw for i in label_idx):
            return None, False
        dot = self._follow_leader(label_box)
        if dot:
            return dot, True
        limit = max(SNAP_DISTANCE_EM * size, 4.0)
        members = set(label_idx)
        nearby = sorted(
            (not s.is_dot, g, i) for i, s in enumerate(self.symbols) if (g := _gap(s.bbox, label_box)) <= limit
        )
        for *_, i in nearby:
            symbol = self.symbols[i]
            if self._symbol_owner(symbol) in members:
                if not symbol.is_dot and (dot := self._follow_leader(symbol.bbox)):
                    return dot, True
                return symbol, False
        return None, False

    def locate(self, name: str, snap: bool = True) -> list[Hit]:
        """All occurrences of `name` on the map, best first.

        Ranking prefers labels that are exactly the name (not "To Glacier Point" or
        "Glacier Point Road"), labels anchored to a map symbol (especially via a leader line),
        and larger type.
        """
        hits = []
        seen = set()
        for indices in self._matches(name):
            match_box = _union(self.chars[i].bbox for i in indices)
            if _inside(match_box, self.exclude):
                continue
            label_idx = self._grow_label(indices)
            key = tuple(label_idx)
            if key in seen:
                continue
            seen.add(key)
            label_box = _union(self.chars[i].bbox for i in label_idx)
            size = round(self.chars[indices[0]].size, 2)  # 4.99997 pt is 5 pt; keeps ties exact
            standalone = normalize("".join(self.chars[i].raw for i in label_idx)) == normalize(name)
            symbol, via_leader = self._snap(label_idx, label_box, size) if snap else (None, False)
            x, y = symbol.center if symbol else ((match_box[0] + match_box[2]) / 2, (match_box[1] + match_box[3]) / 2)
            lat, lon = self.to_latlon(x, y)
            hit = Hit(
                query=name,
                label=self._label_text(label_idx),
                lat=lat,
                lon=lon,
                page_xy=(x, y),
                label_bbox=label_box,
                font_size=size,
                standalone=standalone,
                symbol=symbol,
                via_leader=via_leader,
            )
            # an explicit leader line is the cartographer pinning the exact spot
            hit.score = 4.0 * standalone + 2.0 * hit.snapped + 0.5 * via_leader + 0.25 * size
            hits.append(hit)
        # ties (a name printed more than once) go top to bottom, then left to right, so every
        # implementation of this ranking (e.g. the app's Kotlin port) agrees
        hits.sort(key=lambda h: (-h.score, round(h.page_xy[1], 2), round(h.page_xy[0], 2)))
        return hits
