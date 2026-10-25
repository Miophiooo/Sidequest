import 'london_time.dart';

const List<Map<String, dynamic>> kDailyChallenges = [
  {
    'de': 'Übersehenes Detail',
    'en': 'Overlooked Detail',
    'desc_de': 'Zeig etwas, das die meisten Leute übersehen.',
    'desc_en': 'Show something that most people overlook.',
    'emoji': '👀',
  },
  {
    'de': 'Genau hier',
    'en': 'Right Here',
    'desc_de': 'Mach ein Foto von dem Ort, an dem du gerade bist.',
    'desc_en': 'Take a photo of the place where you are right now.',
    'emoji': '🚪',
  },
  {
    'de': 'Alltag, aber besonders',
    'en': 'Ordinary, Elevated',
    'desc_de': 'Zeig etwas Alltägliches so, als wär’s besonders.',
    'desc_en': 'Show something ordinary as if it were special.',
    'emoji': '✨',
  },
  {
    'de': 'Zwischenmoment',
    'en': 'In-Between Moment',
    'desc_de':
        'Zeig einen Moment zwischen zwei Dingen (z. B. warten, gehen, überlegen).',
    'desc_en':
        'Show a moment in between two things, like waiting, walking, or thinking.',
    'emoji': '⏳',
  },
  {
    'de': 'Heutige Energie',
    'en': 'Today\'s Energy',
    'desc_de': 'Mach ein Foto, das deine heutige Energie widerspiegelt.',
    'desc_en': 'Take a photo that reflects your energy today.',
    'emoji': '⚡',
  },
  {
    'de': 'Nie gepostet',
    'en': 'Never Posted This',
    'desc_de': 'Zeig etwas, das du sonst nie posten würdest.',
    'desc_en': 'Show something you would normally never post.',
    'emoji': '🫣',
  },
  {
    'de': 'Ruhiger Punkt',
    'en': 'Quiet Thing',
    'desc_de': 'Zeig etwas, das sich entspannend oder ruhig anfühlt.',
    'desc_en': 'Show something that feels relaxing or quiet.',
    'emoji': '🕊️',
  },
  {
    'de': 'Kurzer Halt',
    'en': 'Brief Interruption',
    'desc_de': 'Zeig etwas, das dich kurz aufgehalten hat.',
    'desc_en': 'Show something that briefly stopped you.',
    'emoji': '🛑',
  },
  {
    'de': 'Ohne Kontext',
    'en': 'No Context Needed',
    'desc_de': 'Mach ein Foto, das keinen Kontext braucht.',
    'desc_en': 'Take a photo that needs no context.',
    'emoji': '📸',
  },
  {
    'de': 'Fast vergessen',
    'en': 'Almost Forgotten',
    'desc_de': 'Zeig etwas, das du fast vergessen hast, dass es existiert.',
    'desc_en': 'Show something that you almost forgot exists.',
    'emoji': '🧠',
  },
  {
    'de': 'Zu früh oder zu spät',
    'en': 'Too Early or Too Late',
    'desc_de':
        'Mach ein Foto von etwas, das gerade nicht ganz in den Moment passt.',
    'desc_en':
        'Take a photo of something that feels slightly out of sync with the moment.',
    'emoji': '🕰️',
  },
  {
    'de': 'Kleine Spur',
    'en': 'Small Trace',
    'desc_de': 'Zeig eine Spur davon, dass jemand kurz vor dir da war.',
    'desc_en': 'Show a trace that someone was here just before you.',
    'emoji': '👣',
  },
  {
    'de': 'Letzter Lichtrest',
    'en': 'Last Light',
    'desc_de': 'Fotografiere das interessanteste Licht, das du heute findest.',
    'desc_en': 'Photograph the most interesting light you find today.',
    'emoji': '🌇',
  },
  {
    'de': 'Unterwegs',
    'en': 'On the Way',
    'desc_de':
        'Zeig etwas, das nach Bewegung aussieht, auch wenn es stillsteht.',
    'desc_en': 'Show something that looks in motion even while standing still.',
    'emoji': '🚶',
  },
  {
    'de': 'Etwas wartet',
    'en': 'Something Waiting',
    'desc_de':
        'Mach ein Foto von etwas, das wirkt, als würde es auf jemanden warten.',
    'desc_en':
        'Take a photo of something that feels like it is waiting for someone.',
    'emoji': '🪑',
  },
  {
    'de': 'Gegenüber',
    'en': 'Across From You',
    'desc_de': 'Zeig, was dir gerade direkt gegenüber ist.',
    'desc_en': 'Show what is directly across from you.',
    'emoji': '↔️',
  },
  {
    'de': 'Gebrauchsspuren',
    'en': 'Signs of Use',
    'desc_de':
        'Zeig etwas, an dem man sehen kann, dass es wirklich benutzt wird.',
    'desc_en': 'Show something that clearly carries signs of being used.',
    'emoji': '🧰',
  },
  {
    'de': 'Schöner als geplant',
    'en': 'Better Than Planned',
    'desc_de': 'Zeig etwas Unordentliches, das auf einmal gut aussieht.',
    'desc_en': 'Show something messy that suddenly looks good.',
    'emoji': '🌀',
  },
  {
    'de': 'Fast symmetrisch',
    'en': 'Almost Symmetric',
    'desc_de': 'Zeig etwas, das fast perfekt aussieht, aber nicht ganz.',
    'desc_en': 'Show something that looks almost perfect, but not quite.',
    'emoji': '🪞',
  },
  {
    'de': 'Private Bühne',
    'en': 'Private Stage',
    'desc_de': 'Mach ein Foto von einem Ort, der wie eine kleine Bühne wirkt.',
    'desc_en': 'Take a photo of a place that feels like a tiny stage.',
    'emoji': '🎭',
  },
  {
    'de': 'Heute geschafft',
    'en': 'Nailed It Today',
    'desc_de': 'Zeig etwas, das dir heute gut gelungen ist.',
    'desc_en': 'Show something you did really well today.',
    'emoji': '🙌',
  },
  {
    'de': 'Heimliche Pose',
    'en': 'Secret Pose',
    'desc_de': 'Mach eine lustige Pose, wenn gerade niemand hinschaut.',
    'desc_en': 'Strike a funny pose while nobody is looking.',
    'emoji': '🤪',
  },
  {
    'de': 'Hat mich zum Lachen gebracht',
    'en': 'Made Me Laugh',
    'desc_de': 'Zeig etwas, das dich heute zum Lachen gebracht hat.',
    'desc_en': 'Show something that made you laugh today.',
    'emoji': '😂',
  },
  {
    'de': 'Etwas Gelbes',
    'en': 'Something Yellow',
    'desc_de': 'Fotografiere das auffälligste Gelb, das du heute findest.',
    'desc_en': 'Photograph the boldest yellow you can find today.',
    'emoji': '💛',
  },
  {
    'de': 'Ferne',
    'en': 'Distance',
    'desc_de':
        'Fotografiere etwas, das weit weg wirkt, obwohl es direkt vor dir ist.',
    'desc_en':
        'Photograph something that feels far away even though it is right in front of you.',
    'emoji': '🌫️',
  },
  {
    'de': 'Kleine Belohnung',
    'en': 'Small Reward',
    'desc_de':
        'Zeig den unspektakulären Moment, der deinen Tag kurz besser gemacht hat.',
    'desc_en':
        'Show the unspectacular moment that briefly made your day better.',
    'emoji': '🍀',
  },
  {
    'de': 'Spur von jemandem',
    'en': 'Trace of Someone',
    'desc_de':
        'Mach ein Foto von etwas, das an eine bestimmte Person erinnert, ohne sie zu zeigen.',
    'desc_en':
        'Take a photo of something that reminds you of a specific person without showing them.',
    'emoji': '🧶',
  },
  {
    'de': 'Sieht nach Zuhause aus',
    'en': 'Looks Like Home',
    'desc_de':
        'Fotografiere etwas, das nach Zuhause aussieht, auch wenn es keins ist.',
    'desc_en': 'Photograph something that looks like home, even if it is not.',
    'emoji': '🏠',
  },
  {
    'de': 'Kleiner Sieg',
    'en': 'Small Win',
    'desc_de': 'Zeig einen kleinen Sieg von heute – egal wie klein.',
    'desc_en': 'Show a small win from today – no matter how small.',
    'emoji': '🏆',
  },
  {
    'de': 'Zu viel',
    'en': 'Too Much',
    'desc_de': 'Zeig etwas, das heute zu laut, zu voll oder zu intensiv wirkt.',
    'desc_en': 'Show something that feels too loud, crowded, or intense today.',
    'emoji': '📢',
  },
  {
    'de': 'Zu wenig',
    'en': 'Too Little',
    'desc_de': 'Fotografiere etwas, von dem du zu wenig hast.',
    'desc_en': 'Photograph something that you have too little of.',
    'emoji': '🫥',
  },
  {
    'de': 'Eine Sache retten',
    'en': 'One Thing You\'d Save',
    'desc_de':
        'Zeig eine Sache in deiner Nähe, die du heute am ehesten retten würdest.',
    'desc_en': 'Show one thing near you that you would save first today.',
    'emoji': '🛟',
  },
  {
    'de': 'Schatten deiner Stimmung',
    'en': 'Shadow of Your Mood',
    'desc_de':
        'Mach ein Bild, das deine Stimmung zeigt, ohne sie direkt zu benennen.',
    'desc_en': 'Make an image that shows your mood without naming it directly.',
    'emoji': '🌘',
  },
  {
    'de': 'Froschperspektive',
    'en': 'Worm\'s-Eye View',
    'desc_de': 'Fotografiere etwas von ganz unten.',
    'desc_en': 'Photograph something from way down low.',
    'emoji': '🐸',
  },
  {
    'de': 'Kurz vor dem Verschwinden',
    'en': 'Before It Disappears',
    'desc_de': 'Zeig etwas, das gleich weg, vorbei oder anders sein wird.',
    'desc_en': 'Show something that is about to disappear, end, or change.',
    'emoji': '🫧',
  },
  {
    'de': 'Fast leer',
    'en': 'Almost Empty',
    'desc_de': 'Zeig etwas, das fast leer ist.',
    'desc_en': 'Show something that is almost empty.',
    'emoji': '🥛',
  },
  {
    'de': 'Gegenlicht',
    'en': 'Against the Light',
    'desc_de': 'Fotografiere etwas im Gegenlicht.',
    'desc_en': 'Photograph something against the light.',
    'emoji': '🌤️',
  },
  {
    'de': 'Heute echt',
    'en': 'Real Today',
    'desc_de': 'Zeig etwas von heute ohne Schönreden, ohne Filter, ohne Pose.',
    'desc_en': 'Show something from today without polish, filters, or posing.',
    'emoji': '📷',
  },
  {
    'de': 'Spur von Bewegung',
    'en': 'Trace of Motion',
    'desc_de':
        'Mach ein Foto, in dem man Bewegung spürt, auch wenn man sie nicht sieht.',
    'desc_en':
        'Take a photo where you can feel motion even if you cannot see it directly.',
    'emoji': '💨',
  },
  {
    'de': 'Klingt anders, als es aussieht',
    'en': 'Sounds Different Than It Looks',
    'desc_de':
        'Zeig etwas, bei dem man den Ton oder die Stimmung sofort mitdenkt.',
    'desc_en':
        'Show something that instantly makes you imagine its sound or mood.',
    'emoji': '🔊',
  },
  {
    'de': 'Zukunft in einem Bild',
    'en': 'Future in One Frame',
    'desc_de':
        'Mach ein Foto von etwas, das schon ein bisschen nach Zukunft aussieht.',
    'desc_en':
        'Take a photo of something that already looks a little like the future.',
    'emoji': '🌅',
  },
  {
    'de': 'Plot Twist',
    'en': 'Plot Twist',
    'desc_de': 'Zeig einen Moment, der plötzlich ganz anders wirkt als zuerst.',
    'desc_en': 'Show a moment that suddenly feels different than it first did.',
    'emoji': '🔀',
  },
  {
    'de': 'NPC oder Legende',
    'en': 'NPC or Legend',
    'desc_de':
        'Mach ein Bild, das entweder komplett nebensächlich oder maximal ikonisch wirkt.',
    'desc_en':
        'Take a photo that feels either totally irrelevant or instantly iconic.',
    'emoji': '🕹️',
  },
  {
    'de': 'Zu gut für heute',
    'en': 'Too Good for Today',
    'desc_de':
        'Zeig etwas, das heute eigentlich viel zu gut oder schön für den Rest des Tages war.',
    'desc_en':
        'Show something that felt way too good or beautiful for the rest of today.',
    'emoji': '🍒',
  },
  {
    'de': 'Nebensache mit Aura',
    'en': 'Minor Thing, Major Aura',
    'desc_de':
        'Fotografiere etwas Kleines, das plötzlich wichtiger wirkt als alles andere.',
    'desc_en':
        'Photograph something small that suddenly feels more important than everything else.',
    'emoji': '💫',
  },
  {
    'de': 'Fast peinlich',
    'en': 'Almost Embarrassing',
    'desc_de':
        'Zeig etwas, das leicht unangenehm ist, aber gerade deshalb gut funktioniert.',
    'desc_en': 'Show something slightly embarrassing that works because of it.',
    'emoji': '😬',
  },
  {
    'de': 'Stilles Chaos',
    'en': 'Quiet Chaos',
    'desc_de':
        'Mach ein Bild von etwas, das ruhig aussieht, aber chaotisch wirkt.',
    'desc_en': 'Take a photo of something that looks calm but feels chaotic.',
    'emoji': '🌪️',
  },
  {
    'de': 'Das hätte ich fast übersehen',
    'en': 'Almost Missed It',
    'desc_de':
        'Zeig etwas, an dem du beinahe vorbeigelaufen wärst, obwohl es eigentlich sehenswert ist.',
    'desc_en':
        'Show something you almost walked past even though it is worth noticing.',
    'emoji': '🛰️',
  },
  {
    'de': 'Endlich gefunden',
    'en': 'Finally Found',
    'desc_de':
        'Mach ein Foto von etwas, das sich nach kleiner Erlösung oder Treffer anfühlt.',
    'desc_en':
        'Take a photo of something that feels like a small relief or a direct hit.',
    'emoji': '🎯',
  },
  {
    'de': 'Bisschen cursed',
    'en': 'Slightly Cursed',
    'desc_de':
        'Zeig etwas, das harmlos ist und trotzdem eine komische Energie hat.',
    'desc_en': 'Show something harmless that still carries weird energy.',
    'emoji': '🫠',
  },
  {
    'de': 'Das würde ich einem Freund schicken',
    'en': 'Would Send to a Friend',
    'desc_de':
        'Fotografiere etwas, das du sofort einer bestimmten Person schicken würdest.',
    'desc_en':
        'Photograph something you would instantly send to a specific friend.',
    'emoji': '📲',
  },
];

DateTime challengeStartLocal(DateTime referenceLocal) {
  final refLondon = toLondonTime(referenceLocal.toUtc());
  final londonDay = DateTime(refLondon.year, refLondon.month, refLondon.day);
  return challengeStartUtcForLondonDay(londonDay).toLocal();
}

/// Difficulty rotation for the daily challenge window.
/// MUST stay identical to `supabase/functions/daily-scheduler/index.ts`
/// (`kDailyChallengeDifficulties`) — the scheduler derives the
/// "10 minutes left" push from the same rotation.
const List<String> kDailyChallengeDifficulties = ['medium', 'easy', 'medium'];

String dailyDifficultyForLondonDay(DateTime londonDay) {
  final daysSinceAnchor = challengeDayIndexForLondonDay(londonDay);
  final idx =
      ((daysSinceAnchor % kDailyChallengeDifficulties.length) +
          kDailyChallengeDifficulties.length) %
      kDailyChallengeDifficulties.length;
  return kDailyChallengeDifficulties[idx];
}

Duration dailyChallengeWindowForDifficulty(String difficulty) {
  switch (difficulty) {
    case 'easy':
      return const Duration(hours: 2);
    case 'hard':
      return const Duration(hours: 9);
    default:
      return const Duration(hours: 5);
  }
}

DateTime challengeEndLocal(DateTime referenceLocal) {
  final refLondon = toLondonTime(referenceLocal.toUtc());
  final londonDay = DateTime(refLondon.year, refLondon.month, refLondon.day);

  final startLondon = challengeStartLondonForDay(londonDay);
  final window = dailyChallengeWindowForDifficulty(
    dailyDifficultyForLondonDay(londonDay),
  );
  final endLondon = startLondon.add(window);
  final cutoffLondon = DateTime(
    londonDay.year,
    londonDay.month,
    londonDay.day,
    23,
    59,
  );
  final clampedLondon = endLondon.isAfter(cutoffLondon)
      ? cutoffLondon
      : endLondon;
  return londonLocalToUtc(clampedLondon).toLocal();
}

DateTime activeLondonChallengeDayFromUtc(DateTime nowUtc) {
  final nowLondonUtc = toLondonTime(nowUtc);
  final nowLondon = DateTime(
    nowLondonUtc.year,
    nowLondonUtc.month,
    nowLondonUtc.day,
    nowLondonUtc.hour,
    nowLondonUtc.minute,
    nowLondonUtc.second,
    nowLondonUtc.millisecond,
    nowLondonUtc.microsecond,
  );
  final londonDay = DateTime(nowLondon.year, nowLondon.month, nowLondon.day);
  final startLondon = challengeStartLondonForDay(londonDay);
  return nowLondon.isBefore(startLondon)
      ? londonDay.subtract(const Duration(days: 1))
      : londonDay;
}

/// Whole hours between the end of the quest a post belongs to and the post
/// (0 if it was posted before the end).
int hoursAfterQuestEnd(DateTime postedAt) {
  final postedUtc = postedAt.toUtc();
  final questDay = activeLondonChallengeDayFromUtc(postedUtc);
  final questEnd = challengeEndLocal(challengeStartUtcForLondonDay(questDay));
  final late = postedUtc.difference(questEnd.toUtc());
  return late.isNegative ? 0 : late.inHours;
}

String activeLondonChallengeDayStrFromUtc(DateTime nowUtc) {
  return londonDateStrFromLondonDay(activeLondonChallengeDayFromUtc(nowUtc));
}
