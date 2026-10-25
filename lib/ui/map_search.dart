import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../ai/assistant.dart';
import '../geo/geo_math.dart';
import '../geo/map_pack.dart';
import '../location/location_service.dart';
import 'theme.dart';

/// One search result: a place printed on the official park map, or one of our POIs.
class MapSearchResult {
  final String name, kind;
  final LatLng location;
  final MapPlace? parkPlace; // set for park-map places (their printed guidance is precomputed)
  const MapSearchResult(this.name, this.kind, this.location, this.parkPlace);
}

/// Search box over the park map's 336 place names and our trailheads / water / help points.
/// Its own state, so typing never rebuilds the map.
class MapSearchBar extends StatefulWidget {
  final Assistant assistant;
  final LocationService location;
  final void Function(MapSearchResult) onPick;
  const MapSearchBar({super.key, required this.assistant, required this.location, required this.onPick});

  @override
  State<MapSearchBar> createState() => _MapSearchBarState();
}

class _MapSearchBarState extends State<MapSearchBar> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  List<MapSearchResult> _results = const [];

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _search(String q) {
    final a = widget.assistant;
    final out = <MapSearchResult>[];
    if (q.trim().length >= 2) {
      final seen = <String>{};
      for (final h in a.mapPack?.search(q, limit: 6) ?? const <PlaceHit>[]) {
        if (seen.add(h.place.text.toLowerCase())) {
          out.add(MapSearchResult(h.place.text, h.place.area ? 'area' : 'park map place', h.place.location, h.place));
        }
      }
      final norm = MapPack.normalize(q);
      for (final p in a.geo?.pois ?? const []) {
        if (out.length >= 8) break;
        if (p.name == 'Unnamed' || !MapPack.normalize(p.name).contains(norm)) continue;
        if (!seen.add(p.name.toLowerCase())) continue; // river samples share a name
        out.add(MapSearchResult(p.name, p.type.name, p.latLng, null));
      }
    }
    setState(() => _results = out);
  }

  void _pick(MapSearchResult r) {
    _focus.unfocus();
    setState(() => _results = const []);
    _text.text = r.name;
    widget.onPick(r);
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.location.fix;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Card(
        child: TextField(
          controller: _text,
          focusNode: _focus,
          textInputAction: TextInputAction.search,
          onChanged: _search,
          onSubmitted: (_) {
            if (_results.isNotEmpty) _pick(_results.first);
          },
          decoration: InputDecoration(
            isDense: true,
            border: InputBorder.none,
            prefixIcon: const Icon(Icons.search, color: kInkMuted),
            hintText: 'Search places on the park map',
            suffixIcon: _text.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () {
                      _text.clear();
                      _search('');
                    },
                  ),
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
      ),
      if (_results.isNotEmpty)
        Card(
          margin: const EdgeInsets.only(top: 4),
          child: Column(children: [
            for (final r in _results)
              ListTile(
                dense: true,
                leading: Icon(r.parkPlace != null ? Icons.place : Icons.hiking, color: kMoss, size: 20),
                title: Text(r.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text([
                  r.kind,
                  if (f != null)
                    '${formatDistance(haversineM(f.lat, f.lon, r.location.latitude, r.location.longitude))} '
                        '${compassShort(bearingDeg(f.lat, f.lon, r.location.latitude, r.location.longitude))}',
                ].join(' · ')),
                onTap: () => _pick(r),
              ),
          ]),
        ),
    ]);
  }
}
