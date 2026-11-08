import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 保存目录设置：优先公共「Download/文件加密」，不可写时退回应用外部存储。
class AppSettings {
  static const _kSaveDir = 'save_dir';
  static const _folderName = '文件加密';

  static Future<String> defaultSaveDir() async {
    for (final candidate in await _candidates()) {
      final dir = Directory(candidate);
      try {
        if (!await dir.exists()) await dir.create(recursive: true);
      } catch (_) {
        continue;
      }
      if (await _isWritable(dir.path)) return dir.path;
    }
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/$_folderName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  /// Android 10 及以下可直接写公共 Download；11+ 受分区存储限制，
  /// 写入探针失败后自动退回应用专属目录。
  static Future<List<String>> _candidates() async {
    final list = <String>[];
    if (Platform.isAndroid) {
      list.add('/storage/emulated/0/Download/$_folderName');
      list.add('/sdcard/Download/$_folderName');
      final ext = await getExternalStorageDirectory();
      if (ext != null) list.add('${ext.path}/$_folderName');
    }
    final docs = await getApplicationDocumentsDirectory();
    list.add('${docs.path}/$_folderName');
    return list;
  }

  static Future<String> saveDir() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_kSaveDir);
    if (saved != null && saved.isNotEmpty) {
      final ok = await _isWritable(saved);
      if (ok) return saved;
    }
    final def = await defaultSaveDir();
    await prefs.setString(_kSaveDir, def);
    return def;
  }

  static Future<void> setSaveDir(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSaveDir, path);
  }

  static Future<void> resetSaveDir() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kSaveDir);
  }

  /// 通过写入探针文件确认目录可写（兼容部分受限路径）。
  static Future<bool> _isWritable(String path) async {
    try {
      final dir = Directory(path);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final probe = File('${dir.path}/.fenc_write_test');
      await probe.writeAsString('1');
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> ensureWritable(String path) => _isWritable(path);
}
