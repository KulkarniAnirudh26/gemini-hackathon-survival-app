"""Safety guidance printed on the map (closures, limits, hazards) and which places it applies to."""
from __future__ import annotations

import math
import re
from dataclasses import dataclass, field

from .locator import Char, GeoPdfMap, Hit, Rect, _gap, _inside, _point_gap, _union

WARNING = re.compile(
    r"\b(closed|closure|limit|no (swimming|boating|trailers|camping|fires?|pets|parking)|not allowed|"
    r"prohibited|mandatory|hazards?|danger(ous)?|unsafe|caution|warning)\b",
    re.I,
)
INFO = re.compile(
    r"\b(summer only|winter only|seasonal|open (sunrise|daily|approx)|available|reservations?|permits?|"
    r"sunrise to sunset|detours?|delays?|shuttle|required)\b",
    re.I,
)
FEATURE = re.compile(
    r"\b((?:[A-Z][\w’']+ )+(?:Road|Rd|Highway|Hwy|Trail|River|Creek)|Highway \d+)\b"
)
DIRECTION = re.compile(r"\b(east|west|north|south) of this point\b", re.I)
OPPOSITE = {"east": "west", "west": "east", "north": "south", "south": "north"}

# A place within this distance of a note's road gets the note. Generous on purpose: a
# campground up a short spur road is still cut off when the main road closes.
CORRIDOR_KM = 2.0
# Notes without a road apply to places this close to the note's anchor.
NEARBY_KM = 2.5
# Long strokes that can be a named linear feature (road, trail, river).
FEATURE_MIN_WIDTH = 0.8
FEATURE_MIN_LENGTH = 40.0
# A feature label sits on its line.
FEATURE_LABEL_DISTANCE = 8.0
# Arrows from a note to "this point": thin dark strokes, straight or curved.
POINTER_MAX_WIDTH = 0.6
POINTER_TOUCH = 5.0
PARK_NOTE_MIN_WORDS = 8


@dataclass
class Note:
    text: str
    severity: str  # "warning" | "info"
    scope: str  # "local" | "park"
    bbox: Rect
    anchor_xy: tuple[float, float] | None = None  # where the note points (or its centre)
    lat: float | None = None
    lon: float | None = None
    feature: str | None = None  # road/trail the note is about, e.g. "Tioga Road"
    direction: str | None = None  # "east" in "closed east of this point"
    pointed: bool = False  # anchor comes from an arrow drawn to the map


@dataclass
class Advisory:
    note: Note
    reason: str
    distance_km: float | None = None


@dataclass
class _Path:
    points: list[tuple[float, float]]
    cumulative: list[float] = field(default_factory=list)

    def __post_init__(self):
        total, self.cumulative = 0.0, [0.0]
        for a, b in zip(self.points, self.points[1:]):
            total += math.dist(a, b)
            self.cumulative.append(total)

    def project(self, p: tuple[float, float]) -> tuple[float, float]:
        """(distance from p to the path, arc-length position of the closest point)."""
        best = (float("inf"), 0.0)
        for i, (a, b) in enumerate(zip(self.points, self.points[1:])):
            dx, dy = b[0] - a[0], b[1] - a[1]
            seg2 = dx * dx + dy * dy
            t = 0.0 if seg2 == 0 else max(0.0, min(1.0, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / seg2))
            q = (a[0] + t * dx, a[1] + t * dy)
            d = math.dist(p, q)
            if d < best[0]:
                best = (d, self.cumulative[i] + t * math.sqrt(seg2))
        return best

    def point_at(self, s: float) -> tuple[float, float]:
        for i in range(len(self.points) - 1):
            if self.cumulative[i + 1] >= s:
                seg = self.cumulative[i + 1] - self.cumulative[i]
                t = 0 if seg == 0 else (s - self.cumulative[i]) / seg
                a, b = self.points[i], self.points[i + 1]
                return a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1])
        return self.points[-1]


def _block_text(chars: list[Char]) -> str:
    return re.sub(r"\s+", " ", "".join(c.raw if c.raw != "\n" else " " for c in chars)).strip()


class Guidance:
    """Extracts the map's safety notes and answers "what applies at this place?".

    >>> g = Guidance(GeoPdfMap.open("yosemite.pdf"))
    >>> for adv in g.for_hit(m.locate("Olmsted Point")[0]):
    ...     print(adv.note.severity, adv.note.text, "-", adv.reason)
    """

    def __init__(self, m: GeoPdfMap):
        self.m = m
        self.km_per_pt = self._km_per_pt()
        self.paths = self._read_paths()
        self.notes = self._read_notes()
        self._feature_paths: dict[str, list[_Path]] = {}

    # -- extraction ------------------------------------------------------------------------

    def _km_per_pt(self) -> float:
        r = self.m.page.rect
        cx, cy = (r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2
        a, b = self.m.to_latlon(cx, cy), self.m.to_latlon(cx + 100, cy)
        return _haversine_km(a, b) / 100

    def _read_paths(self) -> list[_Path]:
        paths = []
        for d in self.m.drawings:
            if d["type"] not in ("s", "fs") or (d.get("width") or 0) < FEATURE_MIN_WIDTH or not d.get("color"):
                continue
            pts = []
            for it in d["items"]:
                if it[0] in ("l", "c"):
                    a, b = it[1], it[-1]
                    if not pts or math.dist(pts[-1], (a.x, a.y)) > 0.01:
                        pts.append((a.x, a.y))
                    pts.append((b.x, b.y))
            if len(pts) >= 2:
                path = _Path(pts)
                if path.cumulative[-1] >= FEATURE_MIN_LENGTH:
                    paths.append(path)
        return paths

    def _blocks(self) -> dict[int, list[Char]]:
        blocks: dict[int, list[Char]] = {}
        for c in self.m.chars:
            blocks.setdefault(c.block, []).append(c)
        return blocks

    def _read_notes(self) -> list[Note]:
        candidates = []  # [bbox, text, size, is_note, is_heading, colour]
        labels = []  # other straight text, for attaching "(summer only)" to its place name
        for chars in self._blocks().values():
            letters = [c for c in chars if c.text]
            if not letters or letters[0].fragment:  # curved text is a name, not a note
                continue
            text = _block_text(chars)
            colour = max({c.style[2] for c in letters}, key=lambda col: sum(c.style[2] == col for c in letters))
            entry = [_union(c.bbox for c in letters), text, max(c.size for c in letters), False, False, colour]
            if WARNING.search(text) or INFO.search(text):
                entry[3] = True
                candidates.append(entry)
            elif FEATURE.fullmatch(text):
                entry[4] = True
                candidates.append(entry)
            else:
                labels.append(entry)

        # A parenthetical qualifier on its own ("(summer only)") belongs to the label it's printed under.
        for entry in [c for c in candidates if c[1].startswith("(")]:
            near = min(labels, key=lambda lb: _gap(lb[0], entry[0]), default=None)
            if near and _gap(near[0], entry[0]) <= 0.5 * max(near[2], entry[2]):
                labels.remove(near)
                entry[0] = _union([near[0], entry[0]])
                entry[1] = f"{near[1]} {entry[1]}"

        # A note printed as several blocks ("Mariposa Grove Road" / "Closed approx. ..." /
        # "25 ft vehicle limit ...") is merged when the blocks touch and share a colour, or one
        # is the road name it is about. Touching notes of different colours stay separate.
        groups = _merge_touching(candidates)
        notes = []
        for group in groups:
            if not any(c[3] for c in group):
                continue  # headings alone aren't guidance
            group.sort(key=lambda c: (round(c[0][1]), c[0][0]))
            text = " ".join(c[1] for c in group)
            bbox = _union(c[0] for c in group)
            park = _inside(bbox, self.m.exclude)
            if park and (len(text.split()) < PARK_NOTE_MIN_WORDS or not re.search(r"\.(\s|$)", text)):
                continue  # legend item captions, not guidance; park-wide notes are sentences
            feature = FEATURE.search(text)
            direction = DIRECTION.search(text)
            note = Note(
                text=text,
                severity="warning" if WARNING.search(text) else "info",
                scope="park" if park else "local",
                bbox=bbox,
                feature=feature.group(1) if feature and not park else None,
                direction=direction.group(1).lower() if direction else None,
            )
            if not park:
                tip = self._pointer_tip(bbox)
                note.pointed = tip is not None
                note.anchor_xy = tip or ((bbox[0] + bbox[2]) / 2, (bbox[1] + bbox[3]) / 2)
                note.lat, note.lon = self.m.to_latlon(*note.anchor_xy)
            notes.append(note)
        return notes

    def _pointer_tip(self, rect: Rect) -> tuple[float, float] | None:
        """Far end of an arrow drawn from the note to the map ("east of this point")."""
        best, best_gap = None, POINTER_TOUCH
        for d in self.m.drawings:
            items = d["items"]
            if d["type"] != "s" or not items or len(items) > 6 or any(it[0] not in ("l", "c") for it in items):
                continue
            color, width = d.get("color"), d.get("width") or 0
            if color is None or max(color) > 0.15 or width > POINTER_MAX_WIDTH:
                continue
            a, b = items[0][1], items[-1][-1]
            for near, far in (((a.x, a.y), (b.x, b.y)), ((b.x, b.y), (a.x, a.y))):
                g = _point_gap(near, rect)
                if g < best_gap and _point_gap(far, rect) > POINTER_TOUCH:
                    best, best_gap = far, g
        return best

    # -- features --------------------------------------------------------------------------

    def _paths_for(self, feature: str) -> list[_Path]:
        """Line paths a named feature is drawn with, found via its labels on the map."""
        if feature not in self._feature_paths:
            names = [feature]
            if feature.endswith(" Road"):
                names.append(feature[: -len("Road")] + "Rd")
            found: list[_Path] = []
            for name in names:
                for indices in self.m._matches(name):
                    # curved labels follow their line glyph by glyph, so measure every glyph
                    centres = [((c.bbox[0] + c.bbox[2]) / 2, (c.bbox[1] + c.bbox[3]) / 2)
                               for c in (self.m.chars[i] for i in indices)]
                    scored = []
                    for p in self.paths:
                        dists = sorted(p.project(c)[0] for c in centres)
                        scored.append((dists[len(dists) // 2], id(p), p))
                    if scored:
                        dist, _, path = min(scored)
                        if dist <= FEATURE_LABEL_DISTANCE and path not in found:
                            found.append(path)
            self._feature_paths[feature] = found
        return self._feature_paths[feature]

    def _section(self, note: Note, path: _Path) -> tuple[float, float] | None:
        """Arc-length range of `path` a directional note covers: from its anchor towards
        `note.direction`, up to the nearest opposite-facing note on the same feature."""
        d, start = path.project(note.anchor_xy)
        if d > FEATURE_LABEL_DISTANCE * 2:
            return None
        ahead = path.point_at(min(start + 20, path.cumulative[-1]))
        behind = path.point_at(max(start - 20, 0))
        axis = 0 if note.direction in ("east", "west") else 1
        sign = 1 if note.direction in ("east", "south") else -1  # page y grows southwards
        forward = (ahead[axis] - behind[axis]) * sign >= 0
        lo, hi = (start, path.cumulative[-1]) if forward else (0.0, start)
        for other in self.notes:
            if other is note or other.feature != note.feature or other.direction != OPPOSITE[note.direction]:
                continue
            od, os_ = path.project(other.anchor_xy)
            if od <= FEATURE_LABEL_DISTANCE * 2 and lo < os_ < hi:
                lo, hi = (lo, os_) if forward else (os_, hi)
        return lo, hi

    # -- lookup ----------------------------------------------------------------------------

    def for_point(self, xy: tuple[float, float], label_bbox: Rect | None = None) -> list[Advisory]:
        """Guidance for a page point (and optionally the label printed there), most relevant first."""
        out = []
        corridor = CORRIDOR_KM / self.km_per_pt
        for note in self.notes:
            if note.scope == "park":
                out.append(Advisory(note, "park-wide"))
                continue
            if label_bbox and _gap(label_bbox, note.bbox) == 0:
                out.append(Advisory(note, "printed with this label", 0.0))
                continue
            paths = self._paths_for(note.feature) if note.feature else []
            matched = False
            for path in paths:
                dist, s = path.project(xy)
                if dist > corridor:
                    continue
                if note.direction:
                    section = self._section(note, path)
                    if section and section[0] <= s <= section[1]:
                        out.append(Advisory(note, f"on {note.feature}, {note.direction} of the marked point",
                                            dist * self.km_per_pt))
                        matched = True
                else:
                    out.append(Advisory(note, f"along {note.feature}", dist * self.km_per_pt))
                    matched = True
                break
            if not matched and not (paths and note.direction):
                km = math.dist(xy, note.anchor_xy) * self.km_per_pt
                if km <= NEARBY_KM:
                    out.append(Advisory(note, f"nearby ({km:.1f} km)", km))
        rank = {"printed with this label": 0, "park-wide": 9}
        out.sort(key=lambda a: (
            rank.get(a.reason, 1 if a.reason.startswith(("on ", "along ")) else 2),
            a.note.severity != "warning",
            a.distance_km or 0,
        ))
        # the same note is often printed more than once along a road; keep the most relevant copy
        seen, unique = set(), []
        for a in out:
            if a.note.text not in seen:
                seen.add(a.note.text)
                unique.append(a)
        return unique

    def for_hit(self, hit: Hit) -> list[Advisory]:
        return self.for_point(hit.page_xy, hit.label_bbox)

    def for_latlon(self, lat: float, lon: float) -> list[Advisory]:
        """Guidance for a GPS position."""
        return self.for_point(self.m.to_page(lat, lon))


def _merge_touching(candidates: list[list]) -> list[list[list]]:
    parent = list(range(len(candidates)))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for i, a in enumerate(candidates):
        for j in range(i + 1, len(candidates)):
            b = candidates[j]
            related = a[5] == b[5] or a[4] or b[4]
            if related and _gap(a[0], b[0]) <= 0.5 * min(a[2], b[2]):
                parent[find(i)] = find(j)
    groups: dict[int, list[list]] = {}
    for i, c in enumerate(candidates):
        groups.setdefault(find(i), []).append(c)
    return list(groups.values())


def _haversine_km(a: tuple[float, float], b: tuple[float, float]) -> float:
    lat1, lon1, lat2, lon2 = map(math.radians, (*a, *b))
    h = math.sin((lat2 - lat1) / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin((lon2 - lon1) / 2) ** 2
    return 2 * 6371.0088 * math.asin(math.sqrt(h))
