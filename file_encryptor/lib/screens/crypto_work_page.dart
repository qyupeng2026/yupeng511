import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';

import '../crypto/engine.dart';
import '../main.dart';
import '../services/app_settings.dart';
import '../services/record_store.dart';

enum WorkMode { encrypt, decrypt }

class CryptoWorkPage extends StatefulWidget {
  final WorkMode mode;
  const CryptoWorkPage({super.key, required this.mode});

  @override
  State<CryptoWorkPage> createState() => _CryptoWorkPageState();
}

class _CryptoWorkPageState extends State<CryptoWorkPage>
    with AutomaticKeepAliveClientMixin {
  String? _filePath;
  String _fileName = '';
  int _fileSize = 0;
  int? _detectedVersion;

  String _algo = 'gcm';
  final _pw1 = TextEditingController();
  final _pw2 = TextEditingController();
  bool _obscure1 = true;
  bool _obscure2 = true;

  bool _busy = false;
  double _progress = 0;
  String _progressText = '准备中…';

  String? _status;
  String _statusType = 'info';

  String? _resultPath;
  String _resultName = '';
  int _resultSize = 0;
  bool _resultSavedToGallery = false;
  bool get _isEncryptMode => widget.mode == WorkMode.encrypt;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _purgeCache();
  }

  @override
  void dispose() {
    _pw1.dispose();
    _pw2.dispose();
    super.dispose();
  }

  String _fmt(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${i == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(v < 10 ? 2 : 1)} ${units[i]}';
  }

  void _showStatus(String msg, [String type = 'info']) {
    if (!mounted) return;
    setState(() {
      _status = msg;
      _statusType = type;
    });
  }

  void _clearResult() {
    _resultPath = null;
    _resultName = '';
    _resultSize = 0;
    _resultSavedToGallery = false;
  }

  String get _cacheTag => _isEncryptMode ? 'encrypt' : 'decrypt';

  Future<Directory> _cacheDir() async {
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}/fenc_cache/$_cacheTag');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<void> _purgeCache() async {
    try {
      final dir = await _cacheDir();
      await for (final entity in dir.list()) {
        if (entity is File) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
    // 清理旧版本遗留在缓存根目录的文件
    try {
      final root = Directory('${(await getTemporaryDirectory()).path}/fenc_cache');
      if (await root.exists()) {
        await for (final e in root.list()) {
          if (e is File) {
            try {
              await e.delete();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
  }

  bool _isImage(String name) =>
      RegExp(r'\.(jpe?g|png|gif|webp|bmp|heic|heif|dng)$', caseSensitive: false)
          .hasMatch(name);

  bool _isVideo(String name) =>
      RegExp(r'\.(mp4|mov|m4v|3gp|mkv|avi|webm)$', caseSensitive: false)
          .hasMatch(name);

  Future<bool> _saveToGallery(String path, String name) async {
    try {
      final has = await Gal.hasAccess(toAlbum: true);
      if (!has) {
        final granted = await Gal.requestAccess(toAlbum: true);
        if (!granted) {
          _showStatus('未获得相册权限，无法保存到相册', 'error');
          return false;
        }
      }
      final isImg = _isImage(name);
      final isVid = _isVideo(name);
      if (!isImg && !isVid) return false;
      try {
        if (isImg) {
          await Gal.putImage(path, album: '文件加密');
        } else {
          await Gal.putVideo(path, album: '文件加密');
        }
      } on GalException catch (e) {
        if (e.type == GalExceptionType.accessDenied) rethrow;
        // 相册创建失败时退回系统默认相册
        if (isImg) {
          await Gal.putImage(path);
        } else {
          await Gal.putVideo(path);
        }
      }
      return true;
    } on GalException catch (e) {
      _showStatus('保存相册失败：${e.type.message}', 'error');
      return false;
    } catch (e) {
      _showStatus('保存相册失败：$e', 'error');
      return false;
    }
  }

  /// 把缓存产物移动到用户设置的保存目录。返回最终路径。
  Future<String> _persistToSaveDir(String from, String name) async {
    final saveDir = await AppSettings.saveDir();
    final dir = Directory(saveDir);
    if (!await dir.exists()) await dir.create(recursive: true);
    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    var candidate = '${dir.path}/$safe';
    var i = 1;
    while (await File(candidate).exists()) {
      final dot = safe.lastIndexOf('.');
      final base = dot > 0 ? safe.substring(0, dot) : safe;
      final ext = dot > 0 ? safe.substring(dot) : '';
      candidate = '${dir.path}/${base}_$i$ext';
      i++;
    }
    await _copyFile(from, candidate);
    try {
      await File(from).delete();
    } catch (_) {}
    return candidate;
  }

  /// 跨文件系统时 rename 会抛 EXDEV，回退为流式复制。
  Future<void> _copyFile(String from, String to) async {
    try {
      await File(from).rename(to);
    } on FileSystemException {
      final sink = File(to).openWrite();
      try {
        await File(from).openRead().pipe(sink);
      } catch (_) {
        try {
          await sink.close();
        } catch (_) {}
        rethrow;
      }
    }
  }

  Future<void> _pickFile() async {
    if (_busy) return;
    final picked = await FilePicker.platform.pickFiles(withData: false);
    if (picked == null || picked.files.isEmpty) return;
    final path = picked.files.single.path;
    if (path == null) return;
    final version = await CryptoEngine.detectVersion(path);
    if (!mounted) return;
    setState(() {
      _filePath = path;
      _fileName = picked.files.single.name;
      _fileSize = picked.files.single.size;
      _detectedVersion = version;
      _status = null;
      _clearResult();
      if (!_isEncryptMode && version != null) {
        _algo = version == kVersionCtr ? 'ctr' : 'gcm';
      }
    });
    if (!_isEncryptMode) {
      if (version == null) {
        _showStatus('该文件不是本工具或 Cloudreve 生成的加密文件，请重新选择', 'warning');
      } else {
        final algo =
            version == kVersionCtr ? 'AES-256-CTR（Cloudreve）' : 'AES-256-GCM';
        _showStatus('检测到加密文件（$algo），输入密码后点击「解密文件」');
      }
    } else if (version != null) {
      _showStatus('该文件已是加密文件，重复加密将嵌套保护', 'warning');
    }
  }

  void _clearFile() {
    if (_busy) return;
    setState(() {
      _filePath = null;
      _fileName = '';
      _fileSize = 0;
      _detectedVersion = null;
      _status = null;
      _pw1.clear();
      _pw2.clear();
      _clearResult();
    });
  }

  String _decryptedName(String name) {
    if (RegExp(r'\.enc$', caseSensitive: false).hasMatch(name)) {
      return name.substring(0, name.length - 4);
    }
    return '$name.dec';
  }

  Future<void> _run() async {
    if (_busy) return;
    if (_filePath == null) {
      _showStatus('请先选择文件', 'error');
      return;
    }
    final pw = _pw1.text;
    final encrypting = _isEncryptMode;
    if (encrypting) {
      if (pw.length < kMinPasswordLen) {
        _showStatus('密码至少需要 $kMinPasswordLen 个字符', 'error');
        return;
      }
      if (pw != _pw2.text) {
        _showStatus('两次输入的密码不一致', 'error');
        return;
      }
    } else {
      if (pw.isEmpty) {
        _showStatus('请输入密码', 'error');
        return;
      }
    }

    final CryptoOp op;
    final String outName;
    final String algorithm;
    if (encrypting) {
      op = _algo == 'ctr' ? CryptoOp.encryptCtr : CryptoOp.encryptGcm;
      outName = '$_fileName.enc';
      algorithm = _algo == 'ctr' ? 'AES-256-CTR' : 'AES-256-GCM';
    } else {
      final v = _detectedVersion;
      if (v == kVersionCtr) {
        op = CryptoOp.decryptCtr;
        algorithm = 'AES-256-CTR';
      } else if (v == kVersionGcm) {
        op = CryptoOp.decryptGcm;
        algorithm = 'AES-256-GCM';
      } else {
        _showStatus('无法识别的加密文件', 'error');
        return;
      }
      outName = _decryptedName(_fileName);
    }

    await _purgeCache();

    setState(() {
      _busy = true;
      _status = null;
      _clearResult();
      _progress = 0;
      _progressText = '正在派生密钥…';
    });

    final watch = Stopwatch()..start();
    try {
      final cacheDir = await _cacheDir();
      final tmpOut = '${cacheDir.path}/${DateTime.now().microsecondsSinceEpoch}_$outName';

      await CryptoEngine.run(
        op: op,
        input: _filePath!,
        output: tmpOut,
        password: pw,
        onProgress: (p) {
          if (!mounted) return;
          setState(() {
            _progress = p;
            _progressText = '处理中… ${(p * 100).round()}%';
          });
        },
      );

      final size = await File(tmpOut).length();
      watch.stop();

      // 图片/视频自动存相册并删缓存；其他类型移动到保存目录
      var savedToGallery = false;
      var finalPath = tmpOut;
      var persistFailed = false;

      if (_isImage(outName) || _isVideo(outName)) {
        savedToGallery = await _saveToGallery(tmpOut, outName);
      }

      if (savedToGallery) {
        await _purgeCache();
      } else {
        try {
          finalPath = await _persistToSaveDir(tmpOut, outName);
          await _purgeCache();
        } catch (_) {
          // 保存目录不可写时保留缓存产物，避免用户结果丢失
          persistFailed = true;
        }
      }

      if (!mounted) return;
      setState(() {
        _resultPath = savedToGallery ? null : finalPath;
        _resultName = outName;
        _resultSize = size;
        _resultSavedToGallery = savedToGallery;
      });

      await RecordStore.add(CryptoRecord(
        fileName: _fileName,
        outputName: outName,
        algorithm: algorithm,
        size: size,
        type: encrypting ? RecordType.encrypt : RecordType.decrypt,
        time: DateTime.now(),
      ));

      final secs = (watch.elapsedMilliseconds / 1000).toStringAsFixed(1);
      if (persistFailed) {
        _showStatus(
            '处理完成，用时 $secs 秒，但保存目录不可写，文件暂存在缓存：$finalPath',
            'warning');
      } else if (encrypting) {
        _showStatus('加密完成，用时 $secs 秒，请妥善保管密码', 'success');
      } else if (savedToGallery) {
        _showStatus('解密完成，用时 $secs 秒，已保存到相册并清理缓存', 'success');
      } else {
        _showStatus('解密完成，用时 $secs 秒，已保存到：$finalPath', 'success');
      }
    } catch (e) {
      _showStatus(e.toString().replaceFirst('CryptoException: ', ''), 'error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveResultToGallery() async {
    if (_resultPath == null) return;
    if (!_isImage(_resultName) && !_isVideo(_resultName)) {
      _showStatus('仅支持图片或视频格式存入相册', 'error');
      return;
    }
    final ok = await _saveToGallery(_resultPath!, _resultName);
    if (ok && mounted) {
      try {
        await File(_resultPath!).delete();
      } catch (_) {}
      setState(() {
        _resultPath = null;
        _resultSavedToGallery = true;
      });
      _showStatus('已保存到相册「文件加密」', 'success');
    }
  }

  Future<void> _copyPath() async {
    if (_resultPath == null) return;
    await Clipboard.setData(ClipboardData(text: _resultPath!));
    _showStatus('已复制文件路径', 'success');
  }

  Future<void> _copyDirPath() async {
    if (_resultPath == null) return;
    final dir = File(_resultPath!).parent.path;
    await Clipboard.setData(ClipboardData(text: dir));
    _showStatus('已复制目录路径：$dir', 'success');
  }

  Color get _statusColor {
    switch (_statusType) {
      case 'error':
        return kDanger;
      case 'success':
        return kSuccess;
      case 'warning':
        return const Color(0xFFFACC15);
      default:
        return const Color(0xFFA5B4FC);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 540),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _header(),
                  const SizedBox(height: 18),
                  _buildDropzone(),
                  if (_filePath != null) ...[
                    const SizedBox(height: 14),
                    _buildFileInfo(),
                  ],
                  if (_isEncryptMode) ...[
                    const SizedBox(height: 18),
                    _buildAlgorithmField(),
                  ],
                  const SizedBox(height: 18),
                  _buildPasswordField(),
                  if (_isEncryptMode) ...[
                    const SizedBox(height: 16),
                    _buildConfirmField(),
                  ],
                  const SizedBox(height: 20),
                  _btn(
                    label: _isEncryptMode ? '🔒 加密文件' : '🔓 解密文件',
                    primary: true,
                    onTap: _busy ? null : _run,
                  ),
                  if (_busy) ...[
                    const SizedBox(height: 18),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                        value: _progress == 0 ? null : _progress,
                        minHeight: 8,
                        backgroundColor: kBorder,
                        valueColor: const AlwaysStoppedAnimation(kAccent),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(_progressText,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 12, color: kMuted)),
                  ],
                  if (_status != null) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                      decoration: BoxDecoration(
                        color: _statusColor.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: _statusColor.withValues(alpha: 0.35)),
                      ),
                      child: Text(_status!,
                          style: TextStyle(fontSize: 13, color: _statusColor, height: 1.5)),
                    ),
                  ],
                  if (_resultPath != null || _resultSavedToGallery) ...[
                    const SizedBox(height: 16),
                    _buildResult(),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(_isEncryptMode ? '🔐' : '🔓', style: const TextStyle(fontSize: 22)),
            const SizedBox(width: 9),
            Text(_isEncryptMode ? '文件加密' : '文件解密',
                style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: kText,
                    letterSpacing: 0.3)),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          _isEncryptMode
              ? '本地加密 · 文件不会上传 · 支持两种算法'
              : '自动识别算法 · 输入密码解密 · 文件不会上传',
          style: const TextStyle(fontSize: 12.5, color: kMuted, height: 1.6),
        ),
      ],
    );
  }

  Widget _buildDropzone() {
    return InkWell(
      onTap: _busy ? null : _pickFile,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.02),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kBorder, width: 2),
        ),
        child: Column(
          children: const [
            Text('📂', style: TextStyle(fontSize: 30)),
            SizedBox(height: 10),
            Text('点击选择文件',
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500, color: kText)),
            SizedBox(height: 6),
            Text('支持任意类型的文件', style: TextStyle(fontSize: 12, color: kMuted)),
          ],
        ),
      ),
    );
  }

  Widget _buildFileInfo() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1B222B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kBorder),
      ),
      child: Row(
        children: [
          Text(_detectedVersion != null ? '🔒' : '📄', style: const TextStyle(fontSize: 22)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_fileName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13.5, color: kText)),
                const SizedBox(height: 4),
                Text(_fmt(_fileSize), style: const TextStyle(fontSize: 12, color: kMuted)),
              ],
            ),
          ),
          IconButton(
            onPressed: _busy ? null : _clearFile,
            icon: const Icon(Icons.close, size: 18, color: kMuted),
          ),
        ],
      ),
    );
  }

  Widget _buildAlgorithmField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('加密算法',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: kMuted)),
        const SizedBox(height: 10),
        _algoOption('gcm', 'AES-256-GCM', '推荐', '带认证加密，防篡改，通用安全'),
        const SizedBox(height: 10),
        _algoOption('ctr', 'AES-256-CTR', 'Cloudreve 同款', '信封加密：随机文件密钥 + 主密钥包装，HMAC 完整性校验'),
      ],
    );
  }

  Widget _algoOption(String value, String title, String badge, String desc) {
    final active = _algo == value;
    return InkWell(
      onTap: _busy ? null : () => setState(() => _algo = value),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: active ? kAccent.withValues(alpha: 0.10) : const Color(0xFF1B222B),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: active ? kAccent : kBorder, width: active ? 1.5 : 1),
        ),
        child: Row(
          children: [
            Icon(active ? Icons.radio_button_checked : Icons.radio_button_off,
                size: 18, color: active ? kAccent : kMuted),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(title,
                          style: const TextStyle(
                              fontSize: 13.5, fontWeight: FontWeight.w600, color: kText)),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: kAccent.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(badge,
                            style: const TextStyle(fontSize: 10.5, color: Color(0xFFA5B4FC))),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(desc, style: const TextStyle(fontSize: 11.5, color: kMuted, height: 1.4)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pwField(
    TextEditingController c,
    String hint,
    String label, {
    Widget? tag,
    required bool obscure,
    required VoidCallback onToggle,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label,
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: kMuted)),
            if (tag != null) ...[const SizedBox(width: 8), tag],
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: c,
          obscureText: obscure,
          enabled: !_busy,
          style: const TextStyle(color: kText, fontSize: 14),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: kMuted, fontSize: 13),
            filled: true,
            fillColor: const Color(0xFF1B222B),
            suffixIcon: IconButton(
              onPressed: onToggle,
              icon: Icon(obscure ? Icons.visibility_off : Icons.visibility,
                  size: 19, color: kMuted),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: kBorder),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: kBorder),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: kAccent, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPasswordField() => _pwField(
        _pw1,
        _isEncryptMode ? '输入密码（至少 $kMinPasswordLen 位）' : '输入文件密码',
        '密码',
        obscure: _obscure1,
        onToggle: () => setState(() => _obscure1 = !_obscure1),
      );

  Widget _buildConfirmField() {
    final tag = Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: kBorder, borderRadius: BorderRadius.circular(6)),
      child: const Text('仅加密时需要', style: TextStyle(fontSize: 10.5, color: kMuted)),
    );
    return _pwField(
      _pw2,
      '再次输入密码',
      '确认密码',
      tag: tag,
      obscure: _obscure2,
      onToggle: () => setState(() => _obscure2 = !_obscure2),
    );
  }

  Widget _btn({required String label, required bool primary, VoidCallback? onTap}) {
    return Material(
      color: primary ? kAccent : const Color(0xFF1B222B),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: primary ? null : Border.all(color: kBorder),
          ),
          child: Text(label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: primary ? Colors.white : kText,
              )),
        ),
      ),
    );
  }

  Widget _buildResult() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1B222B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text('✅', style: TextStyle(fontSize: 20)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_resultName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13.5, color: kText)),
                    const SizedBox(height: 3),
                    Text(_fmt(_resultSize),
                        style: const TextStyle(fontSize: 12, color: kMuted)),
                  ],
                ),
              ),
            ],
          ),
          if (_resultSavedToGallery) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: kSuccess.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: kSuccess.withValues(alpha: 0.35)),
              ),
              child: const Text('已保存到相册「文件加密」，临时缓存已清理',
                  style: TextStyle(fontSize: 12.5, color: kSuccess)),
            ),
          ] else ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: kAccent.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: kAccent.withValues(alpha: 0.3)),
              ),
              child: Text('已保存到：$_resultPath',
                  style: const TextStyle(fontSize: 12, color: Color(0xFFA5B4FC))),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: _btn(label: '📋 复制路径', primary: false, onTap: _copyPath)),
                const SizedBox(width: 10),
                Expanded(child: _btn(label: '📁 复制目录', primary: false, onTap: _copyDirPath)),
              ],
            ),
            if (_isImage(_resultName) || _isVideo(_resultName)) ...[
              const SizedBox(height: 10),
              _btn(label: '🖼 存入相册', primary: false, onTap: _saveResultToGallery),
            ],
          ],
        ],
      ),
    );
  }
}
