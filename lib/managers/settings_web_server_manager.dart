import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:momento_booth/main.dart';
import 'package:momento_booth/managers/project_manager.dart';
import 'package:momento_booth/managers/settings_manager.dart';
import 'package:momento_booth/models/project_settings.dart';
import 'package:momento_booth/models/settings.dart';
import 'package:momento_booth/repositories/secrets/secure_storage_secrets_repository.dart';
import 'package:momento_booth/repositories/secrets/secrets_repository.dart';

class SettingsWebServerManager {
  static const int defaultPort = 8765;

  HttpServer? _server;

  int port = defaultPort;
  bool get isRunning => _server != null;

  Future<List<String>> get connectionUrls async =>
      _detectConnectionUrls(port: port);

  static List<String> localUrlsForAddresses(
    Iterable<InternetAddress> addresses, {
    required int port,
  }) {
    final urls = <String>{};

    for (final address in addresses) {
      final isLoopback =
          address.isLoopback ||
          address.address == '127.0.0.1' ||
          address.address == '::1';
      if (!isLoopback) {
        urls.add('https://${address.address}:$port');
      }
    }

    urls.add('https://localhost:$port');
    urls.add('https://127.0.0.1:$port');
    return urls.toList()..sort();
  }

  static Future<List<String>> _detectConnectionUrls({required int port}) async {
    final detected = <InternetAddress>[];
    try {
      final interfaces = await NetworkInterface.list(
        includeLinkLocal: true,
        type: InternetAddressType.IPv4,
      );

      for (final iface in interfaces) {
        detected.addAll(iface.addresses);
      }
    } catch (_) {
      // Fall back to loopback-only addresses when networking metadata is unavailable.
    }

    detected.add(InternetAddress.loopbackIPv4);
    return localUrlsForAddresses(detected, port: port);
  }

  Future<void> initialize() async {
    if (_server != null) return;

    final securityContext = SecurityContext()
      ..useCertificateChainBytes(
        await _loadTlsAsset('settings_server_cert.pem'),
      )
      ..usePrivateKeyBytes(await _loadTlsAsset('settings_server_key.pem'));

    _server = await HttpServer.bindSecure(
      InternetAddress.anyIPv4,
      port,
      securityContext,
      shared: true,
    );
    _server!.listen(_handleRequest);
  }

  Future<List<int>> _loadTlsAsset(String filename) async {
    final sourceFile = File('assets/security/$filename');
    if (sourceFile.existsSync()) return sourceFile.readAsBytes();

    final asset = await rootBundle.load('assets/security/$filename');
    return asset.buffer.asUint8List();
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      if (request.method == 'OPTIONS') {
        _writeCorsHeaders(request.response);
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
        return;
      }

      final secretsRepository =
          getIt.maybeGet<SecretsRepository>() ??
          const SecureStorageSecretsRepository();
      final uriPath = request.uri.path;

      if (uriPath == '/' || uriPath == '/index.html') {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.html
          ..write(_buildSettingsPage())
          ..close();
        return;
      }

      if (uriPath == '/health') {
        await _respondJson(request.response, {'ok': true, 'status': 'running'});
        return;
      }

      if (uriPath == '/settings') {
        switch (request.method) {
          case 'GET':
            await _respondJson(
              request.response,
              getIt<SettingsManager>().settings.toJson(),
            );
            return;
          case 'PUT':
          case 'PATCH':
            final payload = await _readJsonBody(request);
            final updatedSettings = applySettingsUpdate(
              getIt<SettingsManager>().settings,
              payload,
            );
            await getIt<SettingsManager>().updateAndSave(updatedSettings);
            await _respondJson(request.response, updatedSettings.toJson());
            return;
          default:
            request.response.statusCode = HttpStatus.methodNotAllowed;
            await request.response.close();
            return;
        }
      }

      if (uriPath == '/project-settings') {
        final projectManager = getIt<ProjectManager>();
        if (!projectManager.isOpen) {
          await _respondJson(request.response, {
            'error': 'Open a project before editing project settings',
          }, statusCode: HttpStatus.conflict);
          return;
        }

        switch (request.method) {
          case 'GET':
            await _respondJson(
              request.response,
              projectManager.settings.toJson(),
            );
            return;
          case 'PUT':
          case 'PATCH':
            final payload = await _readJsonBody(request);
            final updatedSettings = applyProjectSettingsUpdate(
              projectManager.settings,
              payload,
            );
            await projectManager.updateAndSave(updatedSettings);
            await _respondJson(request.response, updatedSettings.toJson());
            return;
          default:
            request.response.statusCode = HttpStatus.methodNotAllowed;
            await request.response.close();
            return;
        }
      }

      if (uriPath == '/settings/secret') {
        switch (request.method) {
          case 'GET':
            final key = request.uri.queryParameters['key'];
            if (key == null || key.isEmpty) {
              request.response.statusCode = HttpStatus.badRequest;
              await request.response.close();
              return;
            }
            final value = await secretsRepository.getSecret(key) ?? '';
            await _respondJson(request.response, {'key': key, 'value': value});
            return;
          case 'POST':
          case 'PUT':
            final payload = await _readJsonBody(request);
            final key = payload['key']?.toString();
            if (key == null || key.isEmpty) {
              request.response.statusCode = HttpStatus.badRequest;
              await request.response.close();
              return;
            }
            final value = payload['value']?.toString() ?? '';
            if (value.trim().isEmpty) {
              await secretsRepository.deleteSecret(key);
              await _respondJson(request.response, {'key': key, 'value': ''});
              return;
            }
            await secretsRepository.storeSecret(key, value);
            await _respondJson(request.response, {'key': key, 'value': value});
            return;
          case 'DELETE':
            final key = request.uri.queryParameters['key'];
            if (key == null || key.isEmpty) {
              final payload = await _readJsonBody(request);
              final candidate = payload['key']?.toString();
              if (candidate == null || candidate.isEmpty) {
                request.response.statusCode = HttpStatus.badRequest;
                await request.response.close();
                return;
              }
              await secretsRepository.deleteSecret(candidate);
              await _respondJson(request.response, {
                'key': candidate,
                'value': '',
              });
              return;
            }
            await secretsRepository.deleteSecret(key);
            await _respondJson(request.response, {'key': key, 'value': ''});
            return;
          default:
            request.response.statusCode = HttpStatus.methodNotAllowed;
            await request.response.close();
            return;
        }
      }

      if (uriPath == '/settings/reset') {
        if (request.method != 'POST') {
          request.response.statusCode = HttpStatus.methodNotAllowed;
          await request.response.close();
          return;
        }

        final resetSettings = Settings.withDefaults();
        await getIt<SettingsManager>().updateAndSave(resetSettings);
        await _respondJson(
          request.response,
          getIt<SettingsManager>().settings.toJson(),
        );
        return;
      }

      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    } catch (error, stackTrace) {
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.headers.contentType = ContentType.json;
      _writeCorsHeaders(request.response);
      request.response.write(
        jsonEncode({
          'error': error.toString(),
          'stackTrace': stackTrace.toString(),
        }),
      );
      await request.response.close();
    }
  }

  Future<Map<String, dynamic>> _readJsonBody(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    if (body.trim().isEmpty) return <String, dynamic>{};

    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw const FormatException('Request body must be a JSON object');
    }

    return Map<String, dynamic>.from(decoded);
  }

  Future<void> _respondJson(
    HttpResponse response,
    Map<String, dynamic> payload, {
    int statusCode = HttpStatus.ok,
  }) async {
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.json;
    _writeCorsHeaders(response);
    response.write(jsonEncode(payload));
    await response.close();
  }

  void _writeCorsHeaders(HttpResponse response) {
    response.headers.add('Access-Control-Allow-Origin', '*');
    response.headers.add(
      'Access-Control-Allow-Methods',
      'GET, PUT, PATCH, POST, OPTIONS',
    );
    response.headers.add('Access-Control-Allow-Headers', 'Content-Type');
  }

  String _buildSettingsPage() {
    return '''
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>MomentoBooth settings</title>
    <style>
      :root {
        color-scheme: dark;
      }
      body {
        margin: 0;
        background: #0f172a;
        color: #e2e8f0;
        font-family: Inter, system-ui, sans-serif;
        padding: 24px;
      }
      .container {
        max-width: 1120px;
        margin: 0 auto;
      }
      h1 {
        margin-top: 0;
        font-size: 2rem;
      }
      .panel {
        background: rgba(15, 23, 42, 0.8);
        border: 1px solid #334155;
        border-radius: 14px;
        padding: 20px;
        margin-top: 18px;
        box-shadow: 0 10px 30px rgba(0,0,0,0.15);
      }
      .grid {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
        gap: 16px;
      }
      .field {
        display: flex;
        flex-direction: column;
        gap: 8px;
      }
      label {
        font-size: 0.82rem;
        color: #cbd5e1;
      }
      input, select {
        width: 100%;
        box-sizing: border-box;
        padding: 10px 12px;
        border-radius: 8px;
        border: 1px solid #475569;
        background: #111827;
        color: #f8fafc;
        font-size: 1rem;
      }
      input[type="checkbox"] {
        width: 18px;
        height: 18px;
        accent-color: #3b82f6;
      }
      .checkbox-row {
        display: flex;
        align-items: center;
        gap: 10px;
        min-height: 44px;
      }
      .actions {
        display: flex;
        gap: 12px;
        margin-top: 18px;
        flex-wrap: wrap;
      }
      button {
        border: none;
        border-radius: 8px;
        padding: 11px 16px;
        font-weight: 600;
        cursor: pointer;
      }
      .primary {
        background: #2563eb;
        color: white;
      }
      .secondary {
        background: #334155;
        color: white;
      }
      .status {
        margin-top: 14px;
        min-height: 20px;
      }
      .error { color: #fca5a5; }
      .ok { color: #a7f3d0; }
      textarea {
        width: 100%;
        min-height: 360px;
        box-sizing: border-box;
        resize: vertical;
        font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
        background: #0b1120;
        color: #e2e8f0;
        border: 1px solid #475569;
        border-radius: 10px;
        padding: 12px;
      }
    </style>
  </head>
  <body>
    <div class="container">
      <h1>MomentoBooth settings</h1>

      <form id="settingsForm">
        <div class="panel">
          <h2>General</h2>
          <div class="grid">
            <div class="field">
              <label for="captureDelaySeconds">Capture delay seconds</label>
              <input id="captureDelaySeconds" name="captureDelaySeconds" type="number" min="0" step="1" />
            </div>
            <div class="field">
              <label for="collageAspectRatio">Collage aspect ratio</label>
              <input id="collageAspectRatio" name="collageAspectRatio" type="number" min="0.1" step="0.1" />
            </div>
            <div class="field">
              <label for="collagePadding">Collage padding</label>
              <input id="collagePadding" name="collagePadding" type="number" min="0" step="0.1" />
            </div>
            <div class="field checkbox-row">
              <input id="loadLastProject" name="loadLastProject" type="checkbox" />
              <label for="loadLastProject">Load last project on startup</label>
            </div>
            <div class="field checkbox-row">
              <input id="enableWakelock" name="enableWakelock" type="checkbox" />
              <label for="enableWakelock">Keep display awake</label>
            </div>
          </div>
        </div>

        <div class="panel">
          <h2>Project</h2>
          <div class="grid">
            <div class="field checkbox-row">
              <input id="projectShowGallery" name="projectShowGallery" type="checkbox" />
              <label for="projectShowGallery">Allow users to browse the gallery</label>
            </div>
            <div class="field checkbox-row">
              <input id="projectShowMomentoLogo" name="projectShowMomentoLogo" type="checkbox" />
              <label for="projectShowMomentoLogo">Show MomentoBooth logo on touch-to-start screen</label>
            </div>
            <div class="field">
              <label for="projectFixedNumberOfPrints">Fixed number of prints (0 = allow changing)</label>
              <input id="projectFixedNumberOfPrints" name="projectFixedNumberOfPrints" type="number" min="0" max="99" step="1" />
            </div>
          </div>
          <p id="projectSettingsStatus">Project settings require an open project.</p>
        </div>

        <div class="panel">
          <h2>Hardware</h2>
          <div class="grid">
            <div class="field">
              <label for="hardwareCaptureDelaySony">Sony capture delay (ms)</label>
              <input id="hardwareCaptureDelaySony" name="hardwareCaptureDelaySony" type="number" min="0" step="10" />
            </div>
            <div class="field">
              <label for="hardwareCaptureLocation">Capture folder</label>
              <input id="hardwareCaptureLocation" name="hardwareCaptureLocation" type="text" />
            </div>
            <div class="field">
              <label for="hardwareServeFromDirectoryPath">Serve from directory</label>
              <input id="hardwareServeFromDirectoryPath" name="hardwareServeFromDirectoryPath" type="text" />
            </div>
            <div class="field">
              <label for="hardwareCupsUri">CUPS URI</label>
              <input id="hardwareCupsUri" name="hardwareCupsUri" type="text" />
            </div>
            <div class="field">
              <label for="hardwareLiveViewWebcamId">Live view webcam id</label>
              <input id="hardwareLiveViewWebcamId" name="hardwareLiveViewWebcamId" type="text" />
            </div>
            <div class="field">
              <label for="hardwarePrinterQueueWarningThreshold">Printer queue warning threshold</label>
              <input id="hardwarePrinterQueueWarningThreshold" name="hardwarePrinterQueueWarningThreshold" type="number" min="0" step="1" />
            </div>
            <div class="field checkbox-row">
              <input id="hardwareSaveCapturesToDisk" name="hardwareSaveCapturesToDisk" type="checkbox" />
              <label for="hardwareSaveCapturesToDisk">Save captures to disk</label>
            </div>
            <div class="field checkbox-row">
              <input id="hardwareCupsIgnoreTlsErrors" name="hardwareCupsIgnoreTlsErrors" type="checkbox" />
              <label for="hardwareCupsIgnoreTlsErrors">Ignore CUPS TLS errors</label>
            </div>
          </div>
        </div>

        <div class="panel">
          <h2>Output</h2>
          <div class="grid">
            <div class="field">
              <label for="outputJpgQuality">JPG quality</label>
              <input id="outputJpgQuality" name="outputJpgQuality" type="number" min="1" max="100" step="1" />
            </div>
            <div class="field">
              <label for="outputResolutionMultiplier">Resolution multiplier</label>
              <input id="outputResolutionMultiplier" name="outputResolutionMultiplier" type="number" min="0.1" step="0.1" />
            </div>
            <div class="field">
              <label for="outputFirefoxSendServerUrl">Firefox Send URL</label>
              <input id="outputFirefoxSendServerUrl" name="outputFirefoxSendServerUrl" type="text" />
            </div>
            <div class="field">
              <label for="outputFirefoxSendControlCommandTimeout">Firefox Send control timeout (s)</label>
              <input id="outputFirefoxSendControlCommandTimeout" name="outputFirefoxSendControlCommandTimeout" type="number" min="0" step="1" />
            </div>
            <div class="field">
              <label for="outputFirefoxSendTransferTimeout">Firefox Send transfer timeout (s)</label>
              <input id="outputFirefoxSendTransferTimeout" name="outputFirefoxSendTransferTimeout" type="number" min="0" step="1" />
            </div>
            <div class="field checkbox-row">
              <input id="outputEnablePrinting" name="outputEnablePrinting" type="checkbox" />
              <label for="outputEnablePrinting">Enable printing</label>
            </div>
            <div class="field checkbox-row">
              <input id="outputEnableFirefoxSend" name="outputEnableFirefoxSend" type="checkbox" />
              <label for="outputEnableFirefoxSend">Enable Firefox Send</label>
            </div>
          </div>
        </div>

        <div class="panel">
          <h2>User interface</h2>
          <div class="grid">
            <div class="field">
              <label for="uiReturnToHomeTimeoutSeconds">Return to home timeout (s)</label>
              <input id="uiReturnToHomeTimeoutSeconds" name="uiReturnToHomeTimeoutSeconds" type="number" min="0" step="5" />
            </div>
            <div class="field">
              <label for="uiLanguage">Language</label>
              <input id="uiLanguage" name="uiLanguage" type="text" />
            </div>
            <div class="field checkbox-row">
              <input id="uiShowSettingsButton" name="uiShowSettingsButton" type="checkbox" />
              <label for="uiShowSettingsButton">Show settings button</label>
            </div>
            <div class="field checkbox-row">
              <input id="uiAllowScrollGestureWithMouse" name="uiAllowScrollGestureWithMouse" type="checkbox" />
              <label for="uiAllowScrollGestureWithMouse">Allow scroll gesture with mouse</label>
            </div>
            <div class="field checkbox-row">
              <input id="uiShowTouchIndicator" name="uiShowTouchIndicator" type="checkbox" />
              <label for="uiShowTouchIndicator">Show touch indicator</label>
            </div>
            <div class="field checkbox-row">
              <input id="uiEnableSfx" name="uiEnableSfx" type="checkbox" />
              <label for="uiEnableSfx">Enable sound effects</label>
            </div>
          </div>
        </div>

        <div class="panel">
          <h2>Templating</h2>
          <div class="grid">
            <div class="field checkbox-row">
              <input id="useFullFrame1PhotoLayout" name="useFullFrame1PhotoLayout" type="checkbox" />
              <label for="useFullFrame1PhotoLayout">Use full frame layout for one photo</label>
            </div>
          </div>
        </div>

        <div class="panel">
          <h2>MQTT integration</h2>
          <div class="grid">
            <div class="field checkbox-row">
              <input id="mqttEnable" name="mqttEnable" type="checkbox" />
              <label for="mqttEnable">Enable MQTT integration</label>
            </div>
            <div class="field">
              <label for="mqttHost">Broker host</label>
              <input id="mqttHost" name="mqttHost" type="text" />
            </div>
            <div class="field">
              <label for="mqttPort">Broker port</label>
              <input id="mqttPort" name="mqttPort" type="number" min="1" step="1" />
            </div>
            <div class="field">
              <label for="mqttUsername">Username</label>
              <input id="mqttUsername" name="mqttUsername" type="text" />
            </div>
            <div class="field">
              <label for="mqttPassword">Password</label>
              <input id="mqttPassword" name="mqttPassword" type="password" autocomplete="off" />
            </div>
            <div class="field">
              <label for="mqttClientId">Client ID</label>
              <input id="mqttClientId" name="mqttClientId" type="text" />
            </div>
            <div class="field">
              <label for="mqttRootTopic">Root topic</label>
              <input id="mqttRootTopic" name="mqttRootTopic" type="text" />
            </div>
            <div class="field checkbox-row">
              <input id="mqttSecure" name="mqttSecure" type="checkbox" />
              <label for="mqttSecure">Use secure connection</label>
            </div>
            <div class="field checkbox-row">
              <input id="mqttVerifyCertificate" name="mqttVerifyCertificate" type="checkbox" />
              <label for="mqttVerifyCertificate">Verify server certificate</label>
            </div>
            <div class="field checkbox-row">
              <input id="mqttUseWebSocket" name="mqttUseWebSocket" type="checkbox" />
              <label for="mqttUseWebSocket">Use WebSocket</label>
            </div>
            <div class="field checkbox-row">
              <input id="mqttEnableHomeAssistantDiscovery" name="mqttEnableHomeAssistantDiscovery" type="checkbox" />
              <label for="mqttEnableHomeAssistantDiscovery">Enable Home Assistant discovery</label>
            </div>
            <div class="field">
              <label for="mqttHomeAssistantDiscoveryTopicPrefix">Discovery topic prefix</label>
              <input id="mqttHomeAssistantDiscoveryTopicPrefix" name="mqttHomeAssistantDiscoveryTopicPrefix" type="text" />
            </div>
            <div class="field">
              <label for="mqttHomeAssistantComponentId">Device ID</label>
              <input id="mqttHomeAssistantComponentId" name="mqttHomeAssistantComponentId" type="text" />
            </div>
          </div>
        </div>

        <div class="panel">
          <h2>Face recognition</h2>
          <div class="grid">
            <div class="field checkbox-row">
              <input id="faceRecognitionEnable" name="faceRecognitionEnable" type="checkbox" />
              <label for="faceRecognitionEnable">Enable face recognition</label>
            </div>
            <div class="field">
              <label for="faceRecognitionServerUrl">Server URL</label>
              <input id="faceRecognitionServerUrl" name="faceRecognitionServerUrl" type="text" />
            </div>
          </div>
        </div>

        <div class="panel">
          <h2>Immich integration</h2>
          <div class="grid">
            <div class="field checkbox-row">
              <input id="immichEnable" name="immichEnable" type="checkbox" />
              <label for="immichEnable">Enable Immich publishing</label>
            </div>
            <div class="field">
              <label for="immichServerUrl">Immich URL</label>
              <input id="immichServerUrl" name="immichServerUrl" type="text" />
            </div>
            <div class="field">
              <label for="immichAlbumName">Immich album</label>
              <input id="immichAlbumName" name="immichAlbumName" type="text" />
            </div>
            <div class="field">
              <label for="immichApiKey">Immich API key</label>
              <input id="immichApiKey" name="immichApiKey" type="password" autocomplete="off" />
            </div>
          </div>
        </div>

        <div class="panel">
          <h2>Debug</h2>
          <div class="grid">
            <div class="field checkbox-row">
              <input id="debugShowFpsCounter" name="debugShowFpsCounter" type="checkbox" />
              <label for="debugShowFpsCounter">Show FPS counter</label>
            </div>
            <div class="field">
              <label for="debugSimulateCvdSeverity">Simulated CVD severity</label>
              <input id="debugSimulateCvdSeverity" name="debugSimulateCvdSeverity" type="number" min="0" max="9" step="1" />
            </div>
            <div class="field checkbox-row">
              <input id="debugEnableExtensivePrintJobLog" name="debugEnableExtensivePrintJobLog" type="checkbox" />
              <label for="debugEnableExtensivePrintJobLog">Enable extensive print job log</label>
            </div>
          </div>
        </div>

        <div class="actions">
          <button class="primary" type="submit">Save settings</button>
          <button class="secondary" type="button" id="applyRawBtn">Apply full JSON</button>
          <button class="secondary" type="button" id="resetBtn">Reset to defaults</button>
        </div>
      </form>

      <div class="panel">
        <h2>Advanced: full settings JSON</h2>
        <p>Every setting in the app is available here. Edit the JSON below and apply it to update the full configuration.</p>
        <textarea id="rawSettingsJson" spellcheck="false"></textarea>
      </div>

      <div id="status" class="status"></div>
    </div>

    <script>
      const statusEl = document.getElementById('status');
      const form = document.getElementById('settingsForm');
      const rawSettingsJson = document.getElementById('rawSettingsJson');

      function setStatus(message, isError) {
        statusEl.textContent = message;
        statusEl.className = 'status ' + (isError ? 'error' : 'ok');
      }

      function loadForm(settings) {
        document.getElementById('captureDelaySeconds').value = settings.captureDelaySeconds ?? 0;
        document.getElementById('collageAspectRatio').value = settings.collageAspectRatio ?? 1.5;
        document.getElementById('collagePadding').value = settings.collagePadding ?? 0;
        document.getElementById('loadLastProject').checked = !!settings.loadLastProject;
        document.getElementById('enableWakelock').checked = !!settings.enableWakelock;

        document.getElementById('hardwareCaptureDelaySony').value = settings.hardware?.captureDelaySony ?? 200;
        document.getElementById('hardwareCaptureLocation').value = settings.hardware?.captureLocation ?? '';
        document.getElementById('hardwareServeFromDirectoryPath').value = settings.hardware?.serveFromDirectoryPath ?? '';
        document.getElementById('hardwareCupsUri').value = settings.hardware?.cupsUri ?? 'http://localhost:631/';
        document.getElementById('hardwareLiveViewWebcamId').value = settings.hardware?.liveViewWebcamId ?? '';
        document.getElementById('hardwarePrinterQueueWarningThreshold').value = settings.hardware?.printerQueueWarningThreshold ?? 4;
        document.getElementById('hardwareSaveCapturesToDisk').checked = !!settings.hardware?.saveCapturesToDisk;
        document.getElementById('hardwareCupsIgnoreTlsErrors').checked = !!settings.hardware?.cupsIgnoreTlsErrors;

        document.getElementById('outputJpgQuality').value = settings.output?.jpgQuality ?? 80;
        document.getElementById('outputResolutionMultiplier').value = settings.output?.resolutionMultiplier ?? 4;
        document.getElementById('outputFirefoxSendServerUrl').value = settings.output?.firefoxSendServerUrl ?? 'https://send.vis.ee/';
        document.getElementById('outputFirefoxSendControlCommandTimeout').value = settings.output?.firefoxSendControlCommandTimeout ?? 5;
        document.getElementById('outputFirefoxSendTransferTimeout').value = settings.output?.firefoxSendTransferTimeout ?? 15;
        document.getElementById('outputEnablePrinting').checked = !!settings.output?.enablePrinting;
        document.getElementById('outputEnableFirefoxSend').checked = !!settings.output?.enableFirefoxSend;

        document.getElementById('uiReturnToHomeTimeoutSeconds').value = settings.ui?.returnToHomeTimeoutSeconds ?? 45;
        document.getElementById('uiLanguage').value = settings.ui?.language ?? 'english';
        document.getElementById('uiShowSettingsButton').checked = !!settings.ui?.showSettingsButton;
        document.getElementById('uiAllowScrollGestureWithMouse').checked = !!settings.ui?.allowScrollGestureWithMouse;
        document.getElementById('uiShowTouchIndicator').checked = !!settings.ui?.showTouchIndicator;
        document.getElementById('uiEnableSfx').checked = !!settings.ui?.enableSfx;

        document.getElementById('useFullFrame1PhotoLayout').checked = !!settings.output?.useFullFrame1PhotoLayout;

        document.getElementById('mqttEnable').checked = !!settings.mqttIntegration?.enable;
        document.getElementById('mqttHost').value = settings.mqttIntegration?.host ?? 'localhost';
        document.getElementById('mqttPort').value = settings.mqttIntegration?.port ?? 1883;
        document.getElementById('mqttUsername').value = settings.mqttIntegration?.username ?? '';
        document.getElementById('mqttPassword').value = '';
        document.getElementById('mqttClientId').value = settings.mqttIntegration?.clientId ?? '';
        document.getElementById('mqttRootTopic').value = settings.mqttIntegration?.rootTopic ?? 'momentobooth';
        document.getElementById('mqttSecure').checked = !!settings.mqttIntegration?.secure;
        document.getElementById('mqttVerifyCertificate').checked = !!settings.mqttIntegration?.verifyCertificate;
        document.getElementById('mqttUseWebSocket').checked = !!settings.mqttIntegration?.useWebSocket;
        document.getElementById('mqttEnableHomeAssistantDiscovery').checked = !!settings.mqttIntegration?.enableHomeAssistantDiscovery;
        document.getElementById('mqttHomeAssistantDiscoveryTopicPrefix').value = settings.mqttIntegration?.homeAssistantDiscoveryTopicPrefix ?? 'homeassistant';
        document.getElementById('mqttHomeAssistantComponentId').value = settings.mqttIntegration?.homeAssistantComponentId ?? '';

        document.getElementById('faceRecognitionEnable').checked = !!settings.faceRecognition?.enable;
        document.getElementById('faceRecognitionServerUrl').value = settings.faceRecognition?.serverUrl ?? 'http://localhost:3232/';

        document.getElementById('immichEnable').checked = !!settings.immichIntegration?.enable;
        document.getElementById('immichServerUrl').value = settings.immichIntegration?.serverUrl ?? '';
        document.getElementById('immichAlbumName').value = settings.immichIntegration?.albumName ?? '';
        document.getElementById('immichApiKey').value = '';

        document.getElementById('debugShowFpsCounter').checked = !!settings.debug?.showFpsCounter;
        document.getElementById('debugSimulateCvdSeverity').value = settings.debug?.simulateCvdSeverity ?? 9;
        document.getElementById('debugEnableExtensivePrintJobLog').checked = !!settings.debug?.enableExtensivePrintJobLog;

        rawSettingsJson.value = JSON.stringify(settings, null, 2);
      }

      function loadProjectSettings(settings) {
        document.getElementById('projectShowGallery').checked = settings.showGallery !== false;
        document.getElementById('projectShowMomentoLogo').checked = settings.showMomentoLogo !== false;
        document.getElementById('projectFixedNumberOfPrints').value = settings.fixedNumberOfPrints ?? 0;
        document.getElementById('projectSettingsStatus').textContent = 'Project settings loaded';
      }

      function collectSettings() {
        return {
          captureDelaySeconds: Number(document.getElementById('captureDelaySeconds').value),
          collageAspectRatio: Number(document.getElementById('collageAspectRatio').value),
          collagePadding: Number(document.getElementById('collagePadding').value),
          loadLastProject: document.getElementById('loadLastProject').checked,
          enableWakelock: document.getElementById('enableWakelock').checked,
          hardware: {
            captureDelaySony: Number(document.getElementById('hardwareCaptureDelaySony').value),
            captureLocation: document.getElementById('hardwareCaptureLocation').value,
            serveFromDirectoryPath: document.getElementById('hardwareServeFromDirectoryPath').value,
            cupsUri: document.getElementById('hardwareCupsUri').value,
            liveViewWebcamId: document.getElementById('hardwareLiveViewWebcamId').value,
            printerQueueWarningThreshold: Number(document.getElementById('hardwarePrinterQueueWarningThreshold').value),
            saveCapturesToDisk: document.getElementById('hardwareSaveCapturesToDisk').checked,
            cupsIgnoreTlsErrors: document.getElementById('hardwareCupsIgnoreTlsErrors').checked,
          },
          output: {
            jpgQuality: Number(document.getElementById('outputJpgQuality').value),
            resolutionMultiplier: Number(document.getElementById('outputResolutionMultiplier').value),
            firefoxSendServerUrl: document.getElementById('outputFirefoxSendServerUrl').value,
            firefoxSendControlCommandTimeout: Number(document.getElementById('outputFirefoxSendControlCommandTimeout').value),
            firefoxSendTransferTimeout: Number(document.getElementById('outputFirefoxSendTransferTimeout').value),
            enablePrinting: document.getElementById('outputEnablePrinting').checked,
            enableFirefoxSend: document.getElementById('outputEnableFirefoxSend').checked,
            useFullFrame1PhotoLayout: document.getElementById('useFullFrame1PhotoLayout').checked,
          },
          ui: {
            returnToHomeTimeoutSeconds: Number(document.getElementById('uiReturnToHomeTimeoutSeconds').value),
            language: document.getElementById('uiLanguage').value,
            showSettingsButton: document.getElementById('uiShowSettingsButton').checked,
            allowScrollGestureWithMouse: document.getElementById('uiAllowScrollGestureWithMouse').checked,
            showTouchIndicator: document.getElementById('uiShowTouchIndicator').checked,
            enableSfx: document.getElementById('uiEnableSfx').checked,
          },
          mqttIntegration: {
            enable: document.getElementById('mqttEnable').checked,
            host: document.getElementById('mqttHost').value,
            port: Number(document.getElementById('mqttPort').value),
            username: document.getElementById('mqttUsername').value,
            clientId: document.getElementById('mqttClientId').value,
            rootTopic: document.getElementById('mqttRootTopic').value,
            secure: document.getElementById('mqttSecure').checked,
            verifyCertificate: document.getElementById('mqttVerifyCertificate').checked,
            useWebSocket: document.getElementById('mqttUseWebSocket').checked,
            enableHomeAssistantDiscovery: document.getElementById('mqttEnableHomeAssistantDiscovery').checked,
            homeAssistantDiscoveryTopicPrefix: document.getElementById('mqttHomeAssistantDiscoveryTopicPrefix').value,
            homeAssistantComponentId: document.getElementById('mqttHomeAssistantComponentId').value,
          },
          faceRecognition: {
            enable: document.getElementById('faceRecognitionEnable').checked,
            serverUrl: document.getElementById('faceRecognitionServerUrl').value,
          },
          immichIntegration: {
            enable: document.getElementById('immichEnable').checked,
            serverUrl: document.getElementById('immichServerUrl').value,
            albumName: document.getElementById('immichAlbumName').value,
          },
          debug: {
            showFpsCounter: document.getElementById('debugShowFpsCounter').checked,
            simulateCvdSeverity: Number(document.getElementById('debugSimulateCvdSeverity').value),
            enableExtensivePrintJobLog: document.getElementById('debugEnableExtensivePrintJobLog').checked,
          },
        };
      }

      async function refreshProjectSettings() {
        const response = await fetch('/project-settings');
        if (response.status === 409) {
          document.getElementById('projectSettingsStatus').textContent = 'Open a project in MomentoBooth to edit project settings.';
          return;
        }
        if (!response.ok) throw new Error('Could not load project settings');
        loadProjectSettings(await response.json());
      }

      async function saveProjectSettings() {
        const response = await fetch('/project-settings', {
          method: 'PUT',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            showGallery: document.getElementById('projectShowGallery').checked,
            showMomentoLogo: document.getElementById('projectShowMomentoLogo').checked,
            fixedNumberOfPrints: Math.max(0, Math.min(99, Number(document.getElementById('projectFixedNumberOfPrints').value))),
          }),
        });
        if (response.status === 409) {
          document.getElementById('projectSettingsStatus').textContent = 'Open a project in MomentoBooth to edit project settings.';
          return;
        }
        const body = await response.text();
        if (!response.ok) throw new Error(body || 'Could not save project settings');
        loadProjectSettings(JSON.parse(body));
      }

      async function saveSecret(key, value) {
        const normalized = (value ?? '').toString();
        const body = JSON.stringify({ key, value: normalized });
        const response = await fetch('/settings/secret', {
          method: normalized.trim() ? 'PUT' : 'DELETE',
          headers: { 'Content-Type': 'application/json' },
          body: normalized.trim() ? body : JSON.stringify({ key }),
        });
        if (!response.ok) {
          throw new Error('Failed to save secret ' + key);
        }
      }

      async function refreshSettings() {
        try {
          const response = await fetch('/settings');
          if (!response.ok) throw new Error('Could not load settings');
          const data = await response.json();
          loadForm(data);
          setStatus('Loaded current settings');
        } catch (error) {
          setStatus('Error loading settings: ' + error.message, true);
        }
      }

      form.addEventListener('submit', async (event) => {
        event.preventDefault();
        try {
          const payload = collectSettings();
          const response = await fetch('/settings', {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload),
          });

          const body = await response.text();
          if (!response.ok) throw new Error(body || 'Save failed');

          const saved = JSON.parse(body);

          const mqttPassword = document.getElementById('mqttPassword').value;
          const immichApiKey = document.getElementById('immichApiKey').value;
          await saveSecret('mqtt_password', mqttPassword);
          await saveSecret('immich_api_key', immichApiKey);

          await saveProjectSettings();

          loadForm(saved);
          setStatus('Settings saved successfully');
        } catch (error) {
          setStatus('Save failed: ' + error.message, true);
        }
      });

      document.getElementById('applyRawBtn').addEventListener('click', async () => {
        try {
          const parsed = JSON.parse(rawSettingsJson.value);
          const response = await fetch('/settings', {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(parsed),
          });

          const body = await response.text();
          if (!response.ok) throw new Error(body || 'Apply raw JSON failed');

          const updated = JSON.parse(body);
          loadForm(updated);
          setStatus('Full settings JSON applied successfully');
        } catch (error) {
          setStatus('Failed to apply full JSON: ' + error.message, true);
        }
      });

      document.getElementById('resetBtn').addEventListener('click', async () => {
        try {
          const response = await fetch('/settings/reset', { method: 'POST' });
          const body = await response.text();
          if (!response.ok) throw new Error(body || 'Reset failed');

          const defaults = JSON.parse(body);
          await saveSecret('mqtt_password', '');
          await saveSecret('immich_api_key', '');
          loadForm(defaults);
          setStatus('Settings reset to defaults');
        } catch (error) {
          setStatus('Reset failed: ' + error.message, true);
        }
      });

      refreshSettings();
      refreshProjectSettings().catch((error) => {
        document.getElementById('projectSettingsStatus').textContent = 'Project settings unavailable: ' + error.message;
      });
    </script>
  </body>
</html>
''';
  }

  static Settings applySettingsUpdate(
    Settings current,
    Map<String, dynamic> update,
  ) {
    final merged = Map<String, dynamic>.from(current.toJson());
    _deepMerge(merged, update);
    return Settings.fromJson(merged);
  }

  static ProjectSettings applyProjectSettingsUpdate(
    ProjectSettings current,
    Map<String, dynamic> update,
  ) {
    final merged = Map<String, dynamic>.from(current.toJson());
    _deepMerge(merged, update);
    return ProjectSettings.fromJson(merged);
  }

  static void _deepMerge(
    Map<String, dynamic> target,
    Map<String, dynamic> source,
  ) {
    for (final entry in source.entries) {
      final key = entry.key;
      final value = entry.value;
      final existing = target[key];

      if (existing is Map && value is Map) {
        final mergedMap = Map<String, dynamic>.from(existing);
        _deepMerge(mergedMap, Map<String, dynamic>.from(value));
        target[key] = mergedMap;
      } else {
        target[key] = value;
      }
    }
  }
}
