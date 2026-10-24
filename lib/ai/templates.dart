import '../geo/geo_math.dart';
import '../rag/guide.dart';
import 'router.dart';
import 'situation.dart';

/// Spoken answers built straight from data: no LLM call.
class Templates {
  static String answer(Intent intent, Situation s) {
    switch (intent) {
      case Intent.findWater:
        return water(s);
      case Intent.wayOut:
        return wayOut(s);
      case Intent.timeDaylight:
        return daylight(s);
      case Intent.whichDirection:
        return direction(s);
      case Intent.findHelp:
        return help(s);
      default:
        return wayOut(s);
    }
  }

  static const _noFix = 'I do not have a GPS fix yet. Step into the open with a clear view of the sky and ask me again in a minute.';

  static String water(Situation s) {
    if (s.fix == null) return _noFix;
    final w = s.water;
    if (w == null) return 'I have no mapped water near you. Head downhill toward a valley, where streams collect, and treat the water before drinking if you can.';
    final (p, d) = w;
    final name = p.name == 'Unnamed' ? 'a water source' : p.name;
    return 'The nearest mapped water is $name, about ${spokenDistance(d)} to the ${s.bearingTo(p)}. '
        'Treat it by boiling or filtering if you can; if not, drink anyway from fast-moving water.';
  }

  static String wayOut(Situation s) {
    if (s.fix == null) return _noFix;
    final r = s.routeOut;
    if (r == null) return 'I could not find a way out on the map near you. Stay where you are, make yourself visible, and signal with three whistle blasts.';
    final b = StringBuffer();
    if (r.offTrail) {
      b.write('You are off trail. The nearest way out is ${r.target.name}, ${spokenDistance(r.distanceM)} to the ${compassWord(r.initialBearing)} in a straight line. ');
      b.write('Cross-country travel is slow and risky; if the terrain is steep, stay put and signal instead. ');
    } else {
      b.write('The nearest way out is ${r.target.name}, ${spokenDistance(r.distanceM)}${r.viaText}. ');
      b.write('Start by heading ${compassWord(r.initialBearing)}. ');
      if (r.ascentM > 50) b.write('There is about ${r.ascentM.round()} meters of climbing. ');
    }
    b.write('It should take about ${spokenDuration(r.walkTime)}. ');
    final us = s.untilSunset;
    if (us != null && !us.isNegative && r.walkTime > us) {
      b.write('That is longer than the ${spokenDuration(us)} of daylight left, so consider stopping to prepare for the night before dark.');
    } else if (s.isNight) {
      b.write('It is dark now. Unless the trail is easy and you have a light, wait for morning.');
    }
    return b.toString().trim();
  }

  static String daylight(Situation s) {
    final t = s.now;
    final hm = '${t.hour % 12 == 0 ? 12 : t.hour % 12}:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
    final us = s.untilSunset;
    if (s.isNight) {
      final rise = s.sun.sunrise;
      return 'It is $hm and it is dark. Sunrise is around ${rise == null ? 'early morning' : '${rise.hour}:${rise.minute.toString().padLeft(2, '0')}'}. Stay warm and wait for light before moving.';
    }
    if (us == null) return 'It is $hm.';
    if (us.isNegative) return 'It is $hm. The sun has set and it will be fully dark soon. Stop and prepare your shelter now.';
    final warn = us < const Duration(hours: 1) ? ' Less than an hour of light remains: find shelter and gather insulation now.' : '';
    return 'It is $hm. Sunset is in ${spokenDuration(us)}.$warn';
  }

  static String direction(Situation s) {
    if (s.fix == null) return _noFix;
    final r = s.routeOut;
    final sunHint = s.isNight
        ? ''
        : ' To find directions without a compass: in the afternoon the sun is in the west; in the morning, the east.';
    if (r == null) return 'I cannot work out a route from here.$sunHint';
    return 'To get out, head ${compassWord(r.initialBearing)} toward ${r.target.name}.$sunHint';
  }

  static String help(Situation s) {
    if (s.fix == null) return _noFix;
    final h = s.help;
    final sos = 'If anyone is hurt, call 911. With no signal, use Satellite SOS from the phone app with a clear view of the sky.';
    if (h == null) return 'There is no ranger station mapped near you. $sos';
    return 'The nearest help is ${h.$1.name}, ${spokenDistance(h.$2)} to the ${s.bearingTo(h.$1)}. $sos';
  }

  static String emergency(RouteDecision d, Guide guide) {
    final b = StringBuffer('If this is life-threatening, call 911 now. With no signal, open the phone app, dial 911 and use Satellite SOS with a clear view of the sky. ');
    final topic = d.topic;
    final section = topic == null ? null : guide.byId(topic);
    if (section != null && (topic == 'bleeding' || topic == 'injury' || topic == 'hypothermia' || topic == 'heat')) {
      b.write(section.summary);
    } else {
      b.write('Check that the person is breathing, press hard on any heavy bleeding, keep them still and warm, and stay together.');
    }
    return b.toString();
  }

  static String guideSummary(String topic, Guide guide) =>
      guide.byId(topic)?.summary ?? guide.byId('lost_stop')!.summary;
}
