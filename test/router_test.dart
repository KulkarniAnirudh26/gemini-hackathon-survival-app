import 'package:flutter_test/flutter_test.dart';
import 'package:yosemite_survival/ai/router.dart';

void main() {
  Route p(Intent i, double conf, {String? topic, double topicConf = 0, double onTopic = 0.9, double urgency = 0, double reasoning = 0.1}) =>
      QuestionRouter.policy(i, conf, topic, topicConf, onTopic, urgency, reasoning);

  test('confident lookups get an instant template answer', () {
    expect(p(Intent.findWater, 0.9), Route.template);
    expect(p(Intent.wayOut, 0.7), Route.template);
  });

  test('a lookup that needs judgement goes to Gemma', () {
    expect(p(Intent.wayOut, 0.9, reasoning: 0.8), Route.llm);
  });

  test('survival topic with low reasoning reads the guide', () {
    expect(p(Intent.other, 0.6, topic: 'bear', topicConf: 0.95), Route.guide);
    expect(p(Intent.survivalHowto, 0.8, topic: 'shelter', topicConf: 0.8), Route.guide);
  });

  test('general and off-topic questions always reach Gemma', () {
    expect(p(Intent.general, 0.9), Route.llm);
    // forced topic guess but Laya says it is not a survival question
    expect(p(Intent.other, 0.5, topic: 'fire', topicConf: 0.9, onTopic: 0.2), Route.llm);
    // "none" topic
    expect(p(Intent.other, 0.5, topic: null, topicConf: 0.9), Route.llm);
  });

  test('emergencies win over everything', () {
    expect(p(Intent.emergency, 0.6), Route.emergency);
    expect(p(Intent.findWater, 0.9, urgency: 2.8), Route.emergency);
  });
}
