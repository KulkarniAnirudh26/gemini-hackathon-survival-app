import 'package:flutter_test/flutter_test.dart';
import 'package:yosemite_survival/ai/router.dart';

void main() {
  Route p(String text, Intent i, double conf, {String? topic, double topicConf = 0, double urgency = 0, double reasoning = 0.1}) =>
      QuestionRouter.policy(
        text: text,
        intent: i,
        conf: conf,
        topic: topic,
        topicConf: topicConf,
        urgency: urgency,
        reasoning: reasoning,
      ).$1;

  test('confident lookups that name the thing get an instant answer', () {
    expect(p('Where is the nearest water?', Intent.findWater, 0.9), Route.template);
    expect(p('How do I get out of here?', Intent.wayOut, 0.8), Route.template);
    expect(p('How long until sunset?', Intent.timeDaylight, 0.8), Route.template);
    // Laya picked the wrong intent but the words are clear
    expect(p('How do I get out of here?', Intent.survivalHowto, 0.96, reasoning: 0.34), Route.template);
    expect(p('Is there a visitor center near me?', Intent.general, 0.69), Route.template);
  });

  test('Laya alone is not enough: the question has to mention it', () {
    // the bug: a confident lookup guess on a question that is not about it
    expect(p("What's the capital of France?", Intent.wayOut, 0.95), Route.llm);
    expect(p('Tell me about Yosemite history', Intent.wayOut, 0.9), Route.llm); // "about" is not "out"
    expect(p('Who was John Muir?', Intent.findWater, 0.9), Route.llm);
  });

  test('lookups that need judgement go to Gemma', () {
    expect(p('Should I go back the way I came or keep going?', Intent.wayOut, 0.9), Route.llm);
    expect(p('I am anxious and alone out here, can you talk to me', Intent.wayOut, 0.8), Route.llm);
    expect(p('Where is the nearest water?', Intent.findWater, 0.9, reasoning: 0.7), Route.llm);
  });

  test('a named danger with low reasoning reads the guide', () {
    expect(p('There is a bear near me.', Intent.other, 0.6, topic: 'bear', topicConf: 0.95), Route.guide);
    expect(p('I saw a cougar on the trail', Intent.survivalHowto, 0.8, topic: 'mountain_lion', topicConf: 0.8), Route.guide);
    expect(p('What animals live here?', Intent.other, 0.6, topic: 'bear', topicConf: 0.95), Route.llm);
    // Laya's intent is noisy: a bear question tagged find_water still reads the bear section
    expect(p('There is a bear near me.', Intent.findWater, 0.64, topic: 'bear', topicConf: 0.98, reasoning: 0.6), Route.guide);
    // "lost" without anyone hurt is the guide, not the emergency script
    expect(p('I think I am lost.', Intent.emergency, 0.97, topic: 'lost_stop', topicConf: 0.9), Route.guide);
  });

  test('general questions go to Gemma', () {
    expect(p("What's the capital of France?", Intent.general, 0.9), Route.llm);
    expect(p('Can you tell me a joke?', Intent.other, 0.4), Route.llm);
  });

  test('emergencies win over everything', () {
    expect(p('My friend is bleeding badly', Intent.general, 0.3), Route.emergency);
    expect(p('Help, my child is missing.', Intent.findHelp, 0.75), Route.emergency);
    expect(p('Where is water', Intent.findWater, 0.9, urgency: 2.8), Route.emergency);
  });

  test('keyword matching respects word boundaries', () {
    expect(QuestionRouter.hasWord('tell me about it', 'out'), isFalse);
    expect(QuestionRouter.hasWord('get me out of here', 'out'), isTrue);
    expect(QuestionRouter.hasWord('be careful', 'car'), isFalse);
    expect(QuestionRouter.hasWord("i'm freezing", 'freez'), isTrue);
    expect(QuestionRouter.topicsMentioned('two bears near camp'), contains('bear'));
  });
}
