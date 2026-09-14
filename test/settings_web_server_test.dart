import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:momento_booth/main.dart';
import 'package:momento_booth/managers/settings_web_server_manager.dart';
import 'package:momento_booth/models/project_settings.dart';
import 'package:momento_booth/models/settings.dart';
import 'package:momento_booth/repositories/secrets/secrets_repository.dart';

class _InMemorySecretsRepository extends SecretsRepository {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<void> storeSecret(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<String?> getSecret(String key) async => _values[key];

  @override
  Future<void> deleteSecret(String key) async {
    _values.remove(key);
  }

  @override
  Future<void> clearSecrets() async {
    _values.clear();
  }
}

void main() {
  group('SettingsWebServerManager', () {
    setUp(() {
      if (getIt.isRegistered<SecretsRepository>()) {
        getIt.unregister<SecretsRepository>();
      }
      getIt.registerSingleton<SecretsRepository>(_InMemorySecretsRepository());
    });

    tearDown(() {
      if (getIt.isRegistered<SecretsRepository>()) {
        getIt.unregister<SecretsRepository>();
      }
    });
    test(
      'mergeSettings preserves existing values and updates requested keys',
      () {
        final original = Settings.withDefaults();

        final updated = SettingsWebServerManager.applySettingsUpdate(original, {
          'captureDelaySeconds': 12,
          'output': {'jpgQuality': 90},
          'hardware': {'captureDelaySony': 250},
        });

        expect(updated.captureDelaySeconds, 12);
        expect(updated.output.jpgQuality, 90);
        expect(updated.hardware.captureDelaySony, 250);
        expect(updated.ui.language, original.ui.language);
      },
    );

    test('project settings can disable gallery browsing without changing other values', () {
      final original = ProjectSettings.withDefaults();

      final updated = SettingsWebServerManager.applyProjectSettingsUpdate(
        original,
        {'showGallery': false},
      );

      expect(updated.showGallery, isFalse);
      expect(updated.showMomentoLogo, original.showMomentoLogo);
      expect(updated.fixedNumberOfPrints, original.fixedNumberOfPrints);
      expect(updated.showGetQrButton, original.showGetQrButton);
    });

    test(
      'localUrlsForAddresses includes local network and loopback fallbacks',
      () {
        final urls = SettingsWebServerManager.localUrlsForAddresses([
          InternetAddress('192.168.1.20'),
          InternetAddress.loopbackIPv4,
          InternetAddress('10.0.0.5'),
        ], port: 8765);

        expect(urls, contains('http://192.168.1.20:8765'));
        expect(urls, contains('http://10.0.0.5:8765'));
        expect(urls, contains('http://localhost:8765'));
        expect(urls, contains('http://127.0.0.1:8765'));
      },
    );

    test('root page mirrors the in-app settings sections', () async {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();

      final server = SettingsWebServerManager()..port = port;
      await server.initialize();

      try {
        final client = HttpClient();
        final request = await client.get('localhost', port, '/');
        final response = await request.close();
        final html = await response.transform(utf8.decoder).join();

        expect(html, contains('General'));
        expect(html, contains('Hardware'));
        expect(html, contains('Output'));
        expect(html, contains('User interface'));
        expect(html, contains('MQTT integration'));
        expect(html, contains('Face recognition'));
        expect(html, contains('Debug'));
        expect(html, contains('Allow users to browse the gallery'));
        expect(html, contains('Fixed number of prints'));
        expect(
          html,
          contains('Show MomentoBooth logo on touch-to-start screen'),
        );
      } finally {
        await server.stop();
      }
    });

    test('browser can store and read secret values', () async {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();

      final server = SettingsWebServerManager()..port = port;
      await server.initialize();

      try {
        final client = HttpClient();

        final saveRequest = await client.post(
          'localhost',
          port,
          '/settings/secret',
        );
        saveRequest.headers.contentType = ContentType.json;
        saveRequest.write(
          jsonEncode({'key': 'immich_api_key', 'value': 'super-secret-key'}),
        );
        final saveResponse = await saveRequest.close();
        expect(saveResponse.statusCode, HttpStatus.ok);

        final readRequest = await client.get(
          'localhost',
          port,
          '/settings/secret?key=immich_api_key',
        );
        final readResponse = await readRequest.close();
        final body = await readResponse.transform(utf8.decoder).join();
        final payload = jsonDecode(body) as Map<String, dynamic>;

        expect(payload['key'], 'immich_api_key');
        expect(payload['value'], 'super-secret-key');
      } finally {
        await server.stop();
      }
    });
  });
}
