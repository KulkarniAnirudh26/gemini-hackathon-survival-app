import 'package:flutter_test/flutter_test.dart';
import 'package:yosemite_survival/ui/theme.dart';

void main() {
  test('Sherpa design theme uses Material 3 and its forest-ink palette', () {
    final theme = survivalTheme();
    expect(theme.useMaterial3, isTrue);
    expect(theme.colorScheme.primary, kInk);
    expect(theme.colorScheme.secondary, kMoss);
  });
}
