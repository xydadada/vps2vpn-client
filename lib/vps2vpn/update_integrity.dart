import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/vps2vpn/update_signing.dart';
import 'package:path/path.dart' show basename;

const vpsInstallerMaxBytes = 512 * 1024 * 1024;
const vpsSignatureMaxBytes = 4096;

Future<bool> vpsVerifyInstaller(
  String path, {
  String publicKeyHex = vpsUpdatePublicKeyHex,
}) => Isolate.run(() => _verifyInstaller(path, publicKeyHex));

Future<bool> _regularFile(String path) async =>
    await FileSystemEntity.type(path, followLinks: false) ==
    FileSystemEntityType.file;

Future<bool> _verifyInstaller(String path, String publicKeyHex) async {
  final signaturePath = '$path.sig';
  try {
    if (!await _regularFile(path) || !await _regularFile(signaturePath)) {
      return false;
    }
    final file = File(path);
    final signature = File(signaturePath);
    final length = await file.length();
    final signatureLength = await signature.length();
    if (length <= 0 ||
        length > vpsInstallerMaxBytes ||
        signatureLength <= 0 ||
        signatureLength > vpsSignatureMaxBytes) {
      return false;
    }
    final signatureBytes = BytesBuilder(copy: false);
    await for (final chunk in signature.openRead(0, vpsSignatureMaxBytes + 1)) {
      signatureBytes.add(chunk);
      if (signatureBytes.length > vpsSignatureMaxBytes) return false;
    }
    var size = 0;
    final digest = await sha256
        .bind(
          file.openRead(0, vpsInstallerMaxBytes + 1).map((chunk) {
            size += chunk.length;
            if (size > vpsInstallerMaxBytes) {
              throw const FormatException('Installer exceeds size limit');
            }
            return chunk;
          }),
        )
        .first;
    if (size != length ||
        signatureBytes.length != signatureLength ||
        !await _regularFile(path) ||
        !await _regularFile(signaturePath)) {
      return false;
    }
    return vpsVerifyUpdate(
      fileName: basename(path),
      sha256Hex: digest.toString(),
      size: size,
      signatureText: utf8.decode(signatureBytes.takeBytes()),
      publicKeyHex: publicKeyHex,
    );
  } on FileSystemException {
    return false;
  } on FormatException {
    return false;
  }
}
