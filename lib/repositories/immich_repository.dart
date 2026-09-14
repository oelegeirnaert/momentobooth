import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:momento_booth/main.dart';
import 'package:momento_booth/models/photo_capture.dart';
import 'package:momento_booth/models/settings.dart';
import 'package:momento_booth/repositories/secrets/secrets_repository.dart';

class ImmichRepository {
  Future<void> publishAll(
    Iterable<PhotoCapture> photos,
    ImmichIntegrationSettings settings,
  ) async {
    for (final photo in photos) {
      await publish(photo, settings);
    }
  }

  Future<void> publish(
    PhotoCapture photo,
    ImmichIntegrationSettings settings,
  ) async {
    final serverUrl = settings.serverUrl.trim();
    if (!settings.enable || serverUrl.isEmpty) return;

    final apiKey = await getIt<SecretsRepository>().getSecret(
      immichApiKeySecretKey,
    );
    if (apiKey == null || apiKey.isEmpty) return;

    final headers = {'x-api-key': apiKey};
    final albumName = settings.albumName.trim();
    final albumId = albumName.isEmpty
        ? null
        : await _getOrCreateAlbum(serverUrl, headers, albumName);

    final now = DateTime.now().toUtc().toIso8601String();
    final request =
        http.MultipartRequest(
            'POST',
            Uri.parse(
              '${serverUrl.replaceFirst(RegExp(r'/*$'), '')}/api/assets',
            ),
          )
          ..headers.addAll(headers)
          ..fields['deviceAssetId'] = photo.filename
          ..fields['deviceId'] = 'momento-booth'
          ..fields['fileCreatedAt'] = now
          ..fields['fileModifiedAt'] = now
          ..files.add(
            http.MultipartFile.fromBytes(
              'assetData',
              photo.data,
              filename: photo.filename,
            ),
          );

    final response = await request.send();
    if (response.statusCode < HttpStatus.ok ||
        response.statusCode >= HttpStatus.multipleChoices) {
      throw HttpException('Immich returned HTTP ${response.statusCode}');
    }

    if (albumId != null) {
      final responseBody = await response.stream.bytesToString();
      final assetId = (jsonDecode(responseBody) as Map<String, dynamic>)['id'];
      if (assetId is! String || assetId.isEmpty) {
        throw const FormatException(
          'Immich upload response did not contain an asset ID',
        );
      }

      final albumResponse = await http.put(
        Uri.parse(
          '${serverUrl.replaceFirst(RegExp(r'/*$'), '')}/api/albums/$albumId/assets',
        ),
        headers: {...headers, 'content-type': 'application/json'},
        body: jsonEncode({
          'ids': [assetId],
        }),
      );
      if (albumResponse.statusCode < HttpStatus.ok ||
          albumResponse.statusCode >= HttpStatus.multipleChoices) {
        throw HttpException(
          'Immich returned HTTP ${albumResponse.statusCode} while adding the asset to album',
        );
      }
    }
  }

  Future<String> _getOrCreateAlbum(
    String serverUrl,
    Map<String, String> headers,
    String albumName,
  ) async {
    final baseUrl = serverUrl.replaceFirst(RegExp(r'/*$'), '');
    final albumsResponse = await http.get(
      Uri.parse('$baseUrl/api/albums'),
      headers: headers,
    );
    if (albumsResponse.statusCode < HttpStatus.ok ||
        albumsResponse.statusCode >= HttpStatus.multipleChoices) {
      throw HttpException(
        'Immich returned HTTP ${albumsResponse.statusCode} while listing albums',
      );
    }

    final albums = jsonDecode(albumsResponse.body) as List<dynamic>;
    for (final album in albums) {
      if (album is Map<String, dynamic> && album['albumName'] == albumName) {
        final albumId = album['id'];
        if (albumId is String && albumId.isNotEmpty) return albumId;
      }
    }

    final createResponse = await http.post(
      Uri.parse('$baseUrl/api/albums'),
      headers: {...headers, 'content-type': 'application/json'},
      body: jsonEncode({'albumName': albumName, 'assetIds': []}),
    );
    if (createResponse.statusCode < HttpStatus.ok ||
        createResponse.statusCode >= HttpStatus.multipleChoices) {
      throw HttpException(
        'Immich returned HTTP ${createResponse.statusCode} while creating album',
      );
    }

    final albumId =
        (jsonDecode(createResponse.body) as Map<String, dynamic>)['id'];
    if (albumId is! String || albumId.isEmpty) {
      throw const FormatException(
        'Immich album response did not contain an album ID',
      );
    }
    return albumId;
  }
}
