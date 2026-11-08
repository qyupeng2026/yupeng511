import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum RecordType { encrypt, decrypt }

class CryptoRecord {
  final String fileName;
  final String outputName;
  final String algorithm;
  final int size;
  final RecordType type;
  final DateTime time;

  const CryptoRecord({
    required this.fileName,
    required this.outputName,
    required this.algorithm,
    required this.size,
    required this.type,
    required this.time,
  });

  Map<String, dynamic> toJson() => {
        'fileName': fileName,
        'outputName': outputName,
        'algorithm': algorithm,
        'size': size,
        'type': type.index,
        'time': time.toIso8601String(),
      };

  static CryptoRecord fromJson(Map<String, dynamic> j) => CryptoRecord(
        fileName: j['fileName'] as String? ?? '',
        outputName: j['outputName'] as String? ?? '',
        algorithm: j['algorithm'] as String? ?? '',
        size: (j['size'] as num?)?.toInt() ?? 0,
        type: RecordType.values[(j['type'] as num?)?.toInt() ?? 0],
        time: DateTime.tryParse(j['time'] as String? ?? '') ?? DateTime.now(),
      );
}

/// 加密 / 解密记录，持久化在 SharedPreferences，最多保留 200 条。
class RecordStore {
  static const _kRecords = 'crypto_records';
  static const _max = 200;

  /// 记录变更信号，供页面监听刷新。
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static Future<List<CryptoRecord>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_kRecords) ?? const [];
    final list = <CryptoRecord>[];
    for (final s in raw) {
      try {
        final m = jsonDecode(s) as Map<String, dynamic>;
        list.add(CryptoRecord.fromJson(m));
      } catch (_) {}
    }
    list.sort((a, b) => b.time.compareTo(a.time));
    return list;
  }

  static Future<void> add(CryptoRecord record) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_kRecords) ?? <String>[];
    raw.insert(0, jsonEncode(record.toJson()));
    final trimmed = raw.take(_max).toList();
    await prefs.setStringList(_kRecords, trimmed);
    revision.value++;
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kRecords);
    revision.value++;
  }

  /// 用给定列表整体覆盖（保持原有排序策略）。
  static Future<void> replaceAll(List<CryptoRecord> records) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = records.take(_max).map((r) => jsonEncode(r.toJson())).toList();
    await prefs.setStringList(_kRecords, trimmed);
    revision.value++;
  }
}
