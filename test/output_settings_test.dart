import 'package:flutter_test/flutter_test.dart';
import 'package:momento_booth/models/settings.dart';

void main() {
  group('output settings defaults', () {
    test('enable printing by default', () {
      final settings = OutputSettings.withDefaults();

      expect(settings.enablePrinting, isTrue);
    });

    test('enable Firefox Send by default', () {
      final settings = OutputSettings.withDefaults();

      expect(settings.enableFirefoxSend, isTrue);
    });

    test('allow disabling both sharing and printing toggles', () {
      final settings = OutputSettings.withDefaults().copyWith(
        enablePrinting: false,
        enableFirefoxSend: false,
      );

      expect(settings.enablePrinting, isFalse);
      expect(settings.enableFirefoxSend, isFalse);
    });
  });

  group('immich integration defaults', () {
    test('start disabled and blank until configured', () {
      final settings = ImmichIntegrationSettings.withDefaults();

      expect(settings.enable, isFalse);
      expect(settings.serverUrl, isEmpty);
      expect(settings.albumName, isEmpty);
    });
  });
}
