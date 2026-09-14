import 'dart:io';

void main() {
  final outputDirectory = Directory('assets/security')..createSync(recursive: true);
  final certificate = File('${outputDirectory.path}/settings_server_cert.pem');
  final privateKey = File('${outputDirectory.path}/settings_server_key.pem');

  if (certificate.existsSync() && privateKey.existsSync()) {
    stdout.writeln('Settings server certificate already exists.');
    return;
  }

  final arguments = [
    'req',
    '-x509',
    '-newkey',
    'rsa:2048',
    '-keyout',
    privateKey.path,
    '-out',
    certificate.path,
    '-days',
    '3650',
    '-nodes',
    '-subj',
    '/CN=MomentoBooth local settings',
  ];
  final result = Process.runSync('openssl', arguments);

  if (result.exitCode != 0) {
    certificate.deleteSync();
    privateKey.deleteSync();
    throw ProcessException(
      'openssl',
      arguments,
      result.stderr.toString(),
      result.exitCode,
    );
  }

  stdout.writeln('Generated settings server certificate and private key.');
}
