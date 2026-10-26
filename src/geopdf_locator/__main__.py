"""CLI: geopdf-locate MAP.pdf "Half Dome" "Glacier Point" [--all] [--json] [--render out.png]
                     [--guidance] [--at LAT,LON]"""
import argparse
import json
import re
import sys
from pathlib import Path

from .guidance import Advisory, Guidance
from .locator import GeoPdfMap
from .render import render_hit


def _render_path(base: Path, name: str, multiple: bool) -> Path:
    """out.png for a single name; out_half-dome.png etc. when several names are rendered."""
    if not multiple:
        return base
    slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return base.with_name(f"{base.stem}_{slug}{base.suffix or '.png'}")


def _advisory_json(a: Advisory) -> dict:
    n = a.note
    return {
        "text": n.text, "severity": n.severity, "reason": a.reason,
        "distance_km": None if a.distance_km is None else round(a.distance_km, 2),
        "feature": n.feature, "lat": None if n.lat is None else round(n.lat, 6),
        "lon": None if n.lon is None else round(n.lon, 6),
    }


def _print_advisories(advisories: list[Advisory]) -> None:
    for a in advisories:
        if a.reason != "park-wide":
            print(f"    {a.note.severity.upper():7s} {a.note.text}  ({a.reason})")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Look up place names on a GeoPDF map.")
    parser.add_argument("pdf")
    parser.add_argument("names", nargs="*")
    parser.add_argument("--all", action="store_true", help="show every hit, not just the best one")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--no-snap", action="store_true", help="use label centres instead of map symbols")
    parser.add_argument("--page", type=int, default=0)
    parser.add_argument(
        "--exclude", action="append", metavar="X0,Y0,X1,Y1", default=None,
        help="ignore a non-map region (legend, notes) in page points; repeatable",
    )
    parser.add_argument(
        "--render", metavar="OUT.png", type=Path,
        help="draw the best hit: close-up to OUT.png, whole map to OUT_overview.png "
             "(one pair per name, suffixed with the name, when several names are given)",
    )
    parser.add_argument("--guidance", action="store_true", help="list the map's safety notes that apply to each hit")
    parser.add_argument(
        "--at", action="append", metavar="LAT,LON", default=[],
        help="list the safety notes that apply at a GPS position; repeatable",
    )
    args = parser.parse_args(argv)
    if not args.names and not args.at:
        parser.error("give at least one place name or --at LAT,LON")

    exclude = [tuple(float(v) for v in e.split(",")) for e in args.exclude] if args.exclude else None
    m = GeoPdfMap.open(args.pdf, args.page, exclude)
    guidance = Guidance(m) if args.guidance or args.at else None
    positions = [tuple(float(v) for v in at.split(",")) for at in args.at]

    results, missing = {}, False
    for name in args.names:
        hits = m.locate(name, snap=not args.no_snap)
        missing |= not hits
        results[name] = hits if args.all else hits[:1]
        if args.render and hits:
            for path in render_hit(m, hits[0], _render_path(args.render, name, len(args.names) > 1)):
                print(f"rendered {path}", file=sys.stderr)

    if args.json:
        out = {}
        for name, hits in results.items():
            out[name] = []
            for h in hits:
                entry = {"label": h.label, "lat": round(h.lat, 6), "lon": round(h.lon, 6), "snapped": h.snapped,
                         "standalone": h.standalone, "score": round(h.score, 2)}
                if guidance:
                    entry["guidance"] = [_advisory_json(a) for a in guidance.for_hit(h)]
                out[name].append(entry)
        for lat, lon in positions:
            out[f"{lat},{lon}"] = [{"lat": lat, "lon": lon,
                                    "guidance": [_advisory_json(a) for a in guidance.for_latlon(lat, lon)]}]
        print(json.dumps(out, indent=2))
    else:
        for name, hits in results.items():
            if not hits:
                print(f"{name}: not found")
            for h in hits:
                flags = ", ".join(f for f, on in [("symbol", h.snapped), ("exact", h.standalone)] if on)
                print(f"{name}: {h.lat:.5f}, {h.lon:.5f}  [{h.label}] score={h.score:.1f} {flags}")
                if guidance:
                    _print_advisories(guidance.for_hit(h))
        for lat, lon in positions:
            print(f"{lat:.5f}, {lon:.5f}:")
            _print_advisories(guidance.for_latlon(lat, lon))
        if guidance:
            park = [n for n in guidance.notes if n.scope == "park"]
            if park:
                print("Park-wide:")
                for n in park:
                    print(f"    {n.severity.upper():7s} {n.text}")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
