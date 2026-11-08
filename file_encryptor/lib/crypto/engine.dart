import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// 与网页版（Web Crypto 实现）完全一致的文件格式：
///   MAGIC "FENC" + 版本号 + 参数头 + 分块密文
/// 版本 1 = AES-256-GCM 分块认证加密
/// 版本 2 = AES-256-CTR 信封加密（随机文件密钥 + 主密钥包装 + HMAC-SHA256）
const List<int> kMagic = [0x46, 0x45, 0x4e, 0x43]; // 'F','E','N','C'
const int kVersionGcm = 1;
const int kVersionCtr = 2;
const int kSaltLen = 16;
const int kIvBaseLen = 8;
const int kCtrIvLen = 16;
const int kChunkSize = 1024 * 1024;
const int kTagLen = 16;
const int kHmacLen = 32;
const int kPbkdf2Iterations = 250000;
const int kGcmHeaderLen = 4 + 1 + kSaltLen + kIvBaseLen + 4; // 33
const int kCtrHeaderLen = 4 + 1 + kSaltLen + kCtrIvLen; // 37
const int kCtrEnvelopeLen = 12 + 64 + kTagLen; // 92
const int kMinPasswordLen = 6;

class CryptoException implements Exception {
  final String message;
  CryptoException(this.message);
  @override
  String toString() => message;
}

enum CryptoOp { encryptGcm, decryptGcm, encryptCtr, decryptCtr }

class CryptoEngine {
  static final Random _rng = Random.secure();

  static Uint8List randomBytes(int len) {
    final b = Uint8List(len);
    for (var i = 0; i < len; i++) {
      b[i] = _rng.nextInt(256);
    }
    return b;
  }

  /// 读取文件头判断是否为本工具生成的加密文件。
  /// 返回 1/2，普通文件返回 null。
  static Future<int?> detectVersion(String path) async {
    final raf = await File(path).open();
    try {
      if (await raf.length() < 5) return null;
      final head = await raf.read(5);
      if (head.length < 5) return null;
      for (var i = 0; i < 4; i++) {
        if (head[i] != kMagic[i]) return null;
      }
      final v = head[4];
      if (v == kVersionGcm || v == kVersionCtr) return v;
      return null;
    } finally {
      await raf.close();
    }
  }

  /// 在独立 isolate 中执行加解密，通过回调回报进度（0..1）。
  static Future<void> run({
    required CryptoOp op,
    required String input,
    required String output,
    required String password,
    void Function(double progress)? onProgress,
  }) async {
    final receive = ReceivePort();
    final completer = Completer<void>();
    late final Isolate isolate;

    receive.listen((message) {
      if (message is Map) {
        if (message.containsKey('p')) {
          onProgress?.call((message['p'] as num).toDouble());
        } else if (message.containsKey('done')) {
          if (!completer.isCompleted) completer.complete();
          receive.close();
        } else if (message.containsKey('error')) {
          if (!completer.isCompleted) {
            completer.completeError(CryptoException(message['error'] as String));
          }
          receive.close();
        }
      } else if (message is List) {
        // isolate 未捕获异常：onError 回传 [error, stackTrace]
        if (!completer.isCompleted) {
          completer.completeError(CryptoException('处理失败：${message.isNotEmpty ? message[0] : '未知错误'}'));
        }
        receive.close();
      }
    }, onDone: () {
      if (!completer.isCompleted) {
        completer.completeError(CryptoException('处理进程异常退出'));
      }
    }, onError: (Object e) {
      if (!completer.isCompleted) {
        completer.completeError(CryptoException('处理进程异常：$e'));
      }
    });

    isolate = await Isolate.spawn<Map<String, dynamic>>(
      _isolateEntry,
      {
        'op': op.index,
        'input': input,
        'output': output,
        'password': password,
        'send': receive.sendPort,
      },
      onError: receive.sendPort,
      onExit: receive.sendPort,
    );

    try {
      await completer.future;
    } finally {
      isolate.kill(priority: Isolate.immediate);
    }
  }

  static void _isolateEntry(Map<String, dynamic> msg) {
    final send = msg['send'] as SendPort;
    try {
      final op = CryptoOp.values[msg['op'] as int];
      final input = msg['input'] as String;
      final output = msg['output'] as String;
      final password = msg['password'] as String;

      void progress(double v) => send.send({'p': v});

      switch (op) {
        case CryptoOp.encryptGcm:
          _encryptGcm(input, output, password, progress);
          break;
        case CryptoOp.decryptGcm:
          _decryptGcm(input, output, password, progress);
          break;
        case CryptoOp.encryptCtr:
          _encryptCtr(input, output, password, progress);
          break;
        case CryptoOp.decryptCtr:
          _decryptCtr(input, output, password, progress);
          break;
      }
      send.send({'done': true});
    } catch (e) {
      send.send({'error': _cleanMessage(e)});
    }
  }

  static String _cleanMessage(Object e) {
    if (e is CryptoException) return e.message;
    return e.toString();
  }

  // ---------------- 密钥派生 ----------------

  static Uint8List _deriveKey(String password, Uint8List salt) {
    final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(salt, kPbkdf2Iterations, 32));
    return derivator.process(Uint8List.fromList(utf8.encode(password)));
  }

  // ---------------- 分块原语 ----------------

  static Uint8List _gcmProcess(
      Uint8List key, Uint8List iv, Uint8List data, Uint8List aad, bool encrypt) {
    final cipher = GCMBlockCipher(AESEngine())
      ..init(encrypt, AEADParameters(KeyParameter(key), 128, iv, aad));
    return cipher.process(data);
  }

  static Uint8List _ctrProcess(
      Uint8List key, Uint8List blockIv, Uint8List data, bool encrypt) {
    final cipher = SICStreamCipher(AESEngine())
      ..init(encrypt, ParametersWithIV(KeyParameter(key), blockIv));
    return cipher.process(data);
  }

  static Uint8List _gcmChunkIv(Uint8List ivBase, int counter) {
    final iv = Uint8List(12);
    iv.setRange(0, 8, ivBase);
    ByteData.view(iv.buffer).setUint32(8, counter, Endian.big);
    return iv;
  }

  static Uint8List _ctrBlockIv(Uint8List iv, int block) {
    final out = Uint8List(kCtrIvLen);
    out.setRange(0, 8, iv.sublist(0, 8));
    ByteData.view(out.buffer).setUint64(8, block, Endian.big);
    return out;
  }

  static Uint8List _buildGcmHeader(Uint8List salt, Uint8List ivBase) {
    final b = Uint8List(kGcmHeaderLen);
    b.setRange(0, 4, kMagic);
    b[4] = kVersionGcm;
    b.setRange(5, 5 + kSaltLen, salt);
    b.setRange(5 + kSaltLen, 5 + kSaltLen + kIvBaseLen, ivBase);
    ByteData.view(b.buffer)
        .setUint32(5 + kSaltLen + kIvBaseLen, kChunkSize, Endian.big);
    return b;
  }

  static Uint8List _buildCtrHeader(Uint8List salt, Uint8List iv) {
    final b = Uint8List(kCtrHeaderLen);
    b.setRange(0, 4, kMagic);
    b[4] = kVersionCtr;
    b.setRange(5, 5 + kSaltLen, salt);
    b.setRange(5 + kSaltLen, 5 + kSaltLen + kCtrIvLen, iv);
    return b;
  }

  static bool _magicOk(List<int> buf) {
    if (buf.length < 5) return false;
    for (var i = 0; i < 4; i++) {
      if (buf[i] != kMagic[i]) return false;
    }
    return true;
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  // ---------------- AES-256-GCM（版本 1） ----------------

  static void _encryptGcm(
      String input, String output, String password, void Function(double) progress) {
    final total = File(input).lengthSync();
    final salt = randomBytes(kSaltLen);
    final ivBase = randomBytes(kIvBaseLen);
    final key = _deriveKey(password, salt);
    final header = _buildGcmHeader(salt, ivBase);

    final inRaf = File(input).openSync();
    final outRaf = File(output).openSync(mode: FileMode.write);
    try {
      outRaf.writeFromSync(header);
      final totalChunks = total == 0 ? 1 : (total / kChunkSize).ceil();
      for (var i = 0; i < totalChunks; i++) {
        final start = i * kChunkSize;
        var len = kChunkSize;
        if (start + len > total) len = total - start;
        if (len < 0) len = 0;
        inRaf.setPositionSync(start);
        final plain = len == 0 ? Uint8List(0) : inRaf.readSync(len);
        final iv = _gcmChunkIv(ivBase, i);
        final aad = Uint8List.fromList([i == totalChunks - 1 ? 1 : 0]);
        // GCM 输出为 密文 || 16 字节认证标签
        final cipher = _gcmProcess(key, iv, plain, aad, true);
        outRaf.writeFromSync(cipher);
        progress((i + 1) / totalChunks);
      }
    } finally {
      inRaf.closeSync();
      outRaf.closeSync();
    }
  }

  static void _decryptGcm(
      String input, String output, String password, void Function(double) progress) {
    final fileLen = File(input).lengthSync();
    if (fileLen < kGcmHeaderLen + kTagLen) {
      throw CryptoException('文件太小，不是有效的 GCM 加密文件');
    }
    final inRaf = File(input).openSync();
    try {
      final header = inRaf.readSync(kGcmHeaderLen);
      if (!_magicOk(header)) throw CryptoException('不是本工具生成的文件');
      if (header[4] != kVersionGcm) throw CryptoException('版本不匹配');

      final salt = Uint8List.fromList(header.sublist(5, 5 + kSaltLen));
      final ivBase = Uint8List.fromList(
          header.sublist(5 + kSaltLen, 5 + kSaltLen + kIvBaseLen));
      final chunkSize = ByteData.view(
              header.buffer, header.offsetInBytes, header.lengthInBytes)
          .getUint32(5 + kSaltLen + kIvBaseLen, Endian.big);
      if (chunkSize == 0 || chunkSize > 64 * 1024 * 1024) {
        throw CryptoException('文件头损坏');
      }

      final key = _deriveKey(password, salt);
      final dataLen = fileLen - kGcmHeaderLen;
      final ctChunkSize = chunkSize + kTagLen;
      final totalChunks = (dataLen / ctChunkSize).ceil();

      final outRaf = File(output).openSync(mode: FileMode.write);
      try {
        inRaf.setPositionSync(kGcmHeaderLen);
        for (var i = 0; i < totalChunks; i++) {
          final processed = i * ctChunkSize;
          var len = ctChunkSize;
          final remaining = dataLen - processed;
          if (len > remaining) len = remaining;
          final cipher = inRaf.readSync(len);
          final iv = _gcmChunkIv(ivBase, i);
          final aad = Uint8List.fromList([i == totalChunks - 1 ? 1 : 0]);
          Uint8List plain;
          try {
            plain = _gcmProcess(key, iv, cipher, aad, false);
          } catch (_) {
            throw CryptoException('解密失败：密码错误或文件已损坏');
          }
          outRaf.writeFromSync(plain);
          progress((i + 1) / totalChunks);
        }
      } finally {
        outRaf.closeSync();
      }
    } finally {
      inRaf.closeSync();
    }
  }

  // ---------------- AES-256-CTR（版本 2） ----------------

  static void _encryptCtr(
      String input, String output, String password, void Function(double) progress) {
    final total = File(input).lengthSync();
    final salt = randomBytes(kSaltLen);
    final iv = randomBytes(kCtrIvLen);
    final fileKey = randomBytes(32);
    final hmacKey = randomBytes(32);

    final wrapKey = _deriveKey(password, salt);
    final keyBundle = Uint8List(64)
      ..setRange(0, 32, fileKey)
      ..setRange(32, 64, hmacKey);
    final wrapIv = randomBytes(12);
    final wrapped =
        _gcmProcess(wrapKey, wrapIv, keyBundle, Uint8List(0), true); // 64 + 16

    final header = Uint8List(kCtrHeaderLen + 12 + wrapped.length);
    header.setRange(0, kCtrHeaderLen, _buildCtrHeader(salt, iv));
    header.setRange(kCtrHeaderLen, kCtrHeaderLen + 12, wrapIv);
    header.setRange(kCtrHeaderLen + 12, header.length, wrapped);

    final inRaf = File(input).openSync();
    final outRaf = File(output).openSync(mode: FileMode.write);
    try {
      outRaf.writeFromSync(header);

      final hmac = HMac(SHA256Digest(), 64)..init(KeyParameter(hmacKey));
      hmac.update(iv, 0, iv.length);

      final totalChunks = total == 0 ? 1 : (total / kChunkSize).ceil();
      for (var i = 0; i < totalChunks; i++) {
        final start = i * kChunkSize;
        var len = kChunkSize;
        if (start + len > total) len = total - start;
        if (len < 0) len = 0;
        inRaf.setPositionSync(start);
        final plain = len == 0 ? Uint8List(0) : inRaf.readSync(len);
        final cipher =
            _ctrProcess(fileKey, _ctrBlockIv(iv, i), plain, true);
        outRaf.writeFromSync(cipher);
        hmac.update(cipher, 0, cipher.length);
        progress((i + 1) / (totalChunks + 1));
      }

      final tag = Uint8List(hmac.macSize);
      hmac.doFinal(tag, 0);
      outRaf.writeFromSync(tag);
      progress(1.0);
    } finally {
      inRaf.closeSync();
      outRaf.closeSync();
    }
  }

  static void _decryptCtr(
      String input, String output, String password, void Function(double) progress) {
    final fileLen = File(input).lengthSync();
    final minLen = kCtrHeaderLen + kCtrEnvelopeLen + kHmacLen;
    if (fileLen < minLen) {
      throw CryptoException('文件太小，不是有效的 CTR 加密文件');
    }

    final inRaf = File(input).openSync();
    try {
      final base = inRaf.readSync(kCtrHeaderLen);
      if (!_magicOk(base)) throw CryptoException('不是本工具生成的文件');
      if (base[4] != kVersionCtr) throw CryptoException('版本不匹配');

      final salt = Uint8List.fromList(base.sublist(5, 5 + kSaltLen));
      final iv = Uint8List.fromList(
          base.sublist(5 + kSaltLen, 5 + kSaltLen + kCtrIvLen));

      final extra = inRaf.readSync(kCtrEnvelopeLen);
      final wrapIv = Uint8List.fromList(extra.sublist(0, 12));
      final wrapped = Uint8List.fromList(extra.sublist(12));

      final wrapKey = _deriveKey(password, salt);
      Uint8List keyBundle;
      try {
        keyBundle =
            _gcmProcess(wrapKey, wrapIv, wrapped, Uint8List(0), false);
      } catch (_) {
        throw CryptoException('解密失败：密码错误或文件已损坏');
      }
      if (keyBundle.length < 64) throw CryptoException('密钥结构异常');
      final fileKey = Uint8List.fromList(keyBundle.sublist(0, 32));
      final hmacKey = Uint8List.fromList(keyBundle.sublist(32, 64));

      final dataStart = kCtrHeaderLen + kCtrEnvelopeLen;
      final dataLen = fileLen - dataStart - kHmacLen;
      if (dataLen < 0) throw CryptoException('文件结构异常');

      // 第一遍：校验 HMAC
      final hmac = HMac(SHA256Digest(), 64)..init(KeyParameter(hmacKey));
      hmac.update(iv, 0, iv.length);
      inRaf.setPositionSync(dataStart);
      var remaining = dataLen;
      while (remaining > 0) {
        final n = remaining < kChunkSize ? remaining : kChunkSize;
        final buf = inRaf.readSync(n);
        if (buf.isEmpty) break;
        hmac.update(buf, 0, buf.length);
        remaining -= buf.length;
        progress(0.5 * (1 - remaining / (dataLen == 0 ? 1 : dataLen)));
      }
      final calc = Uint8List(hmac.macSize);
      hmac.doFinal(calc, 0);

      inRaf.setPositionSync(dataStart + dataLen);
      final tag = inRaf.readSync(kHmacLen);
      if (!_constantTimeEquals(calc, tag)) {
        throw CryptoException('解密失败：密码错误或文件已损坏（HMAC 校验不通过）');
      }

      // 第二遍：解密输出
      final outRaf = File(output).openSync(mode: FileMode.write);
      try {
        final totalChunks = dataLen == 0 ? 1 : (dataLen / kChunkSize).ceil();
        inRaf.setPositionSync(dataStart);
        var left = dataLen;
        for (var i = 0; i < totalChunks; i++) {
          final n = left < kChunkSize ? left : kChunkSize;
          final chunk = n <= 0 ? Uint8List(0) : inRaf.readSync(n);
          left -= chunk.length;
          final plain =
              _ctrProcess(fileKey, _ctrBlockIv(iv, i), chunk, false);
          outRaf.writeFromSync(plain);
          progress(0.5 + 0.5 * (i + 1) / totalChunks);
        }
      } finally {
        outRaf.closeSync();
      }
    } finally {
      inRaf.closeSync();
    }
  }
}
