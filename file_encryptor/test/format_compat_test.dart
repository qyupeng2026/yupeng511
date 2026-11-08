import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:file_encryptor/crypto/engine.dart';

import 'vectors.dart';

// 兼容性回归测试：验证 Dart 实现与网页版 FENC 格式一致。
// 参考向量由网页实现（Web Crypto）生成，见 test/vectors/README.md。

Map<String, Uint8List> _vectors() {
  Uint8List hex(String s) {
    final clean = s.replaceAll(RegExp(r'\s'), '');
    final out = Uint8List(clean.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  return {
    'gcm': hex(gcmVectorHex),
    'ctr': hex(ctrVectorHex),
  };
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fenc_test_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('解密网页版生成的 AES-256-GCM 文件', () async {
    final src = File('${tmp.path}/gcm.enc');
    await src.writeAsBytes(_vectors()['gcm']!);
    expect(await CryptoEngine.detectVersion(src.path), kVersionGcm);

    final out = '${tmp.path}/gcm.out';
    await CryptoEngine.run(
      op: CryptoOp.decryptGcm,
      input: src.path,
      output: out,
      password: testPassword,
    );
    expect(await File(out).readAsString(), testPlaintext);
  });

  test('解密网页版生成的 AES-256-CTR 文件', () async {
    final src = File('${tmp.path}/ctr.enc');
    await src.writeAsBytes(_vectors()['ctr']!);
    expect(await CryptoEngine.detectVersion(src.path), kVersionCtr);

    final out = '${tmp.path}/ctr.out';
    await CryptoEngine.run(
      op: CryptoOp.decryptCtr,
      input: src.path,
      output: out,
      password: testPassword,
    );
    expect(await File(out).readAsString(), testPlaintext);
  });

  test('本实现加密后可自解密（GCM / CTR）', () async {
    final plain = File('${tmp.path}/plain.bin');
    final payload = Uint8List.fromList(List.generate(3000000, (i) => i % 251));
    await plain.writeAsBytes(payload);

    for (final pair in [
      [CryptoOp.encryptGcm, CryptoOp.decryptGcm, 'g'],
      [CryptoOp.encryptCtr, CryptoOp.decryptCtr, 'c'],
    ]) {
      final enc = '${tmp.path}/${pair[2]}.enc';
      final dec = '${tmp.path}/${pair[2]}.dec';
      await CryptoEngine.run(
        op: pair[0] as CryptoOp,
        input: plain.path,
        output: enc,
        password: 'password123',
      );
      await CryptoEngine.run(
        op: pair[1] as CryptoOp,
        input: enc,
        output: dec,
        password: 'password123',
      );
      expect(await File(dec).readAsBytes(), payload);
    }
  });

  test('错误密码解密失败', () async {
    final src = File('${tmp.path}/gcm.enc');
    await src.writeAsBytes(_vectors()['gcm']!);
    final out = '${tmp.path}/bad.out';
    await expectLater(
      CryptoEngine.run(
        op: CryptoOp.decryptGcm,
        input: src.path,
        output: out,
        password: 'wrong-password',
      ),
      throwsA(isA<CryptoException>()),
    );
  });
}
