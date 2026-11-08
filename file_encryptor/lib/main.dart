import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'crypto/engine.dart';

void main() {
  runApp(const FileEncryptorApp());
}

const Color kBg = Color(0xFF0E1116);
const Color kCard = Color(0xFF161B22);
const Color kBorder = Color(0xFF2A313C);
const Color kText = Color(0xFFE6EDF3);
const Color kMuted = Color(0xFF8B949E);
const Color kAccent = Color(0xFF6366F1);
const Color kAccent2 = Color(0xFF8B5CF6);
const Color kDanger = Color(0xFFF85149);
const Color kSuccess = Color(0xFF3FB950);

class FileEncryptorApp extends StatelessWidget {
  const FileEncryptorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '文件加密',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBg,
        colorScheme: const ColorScheme.dark(
          primary: kAccent,
          secondary: kAccent2,
          surface: kCard,
        ),
        fontFamily: 'PingFang SC',
      ),
      home: const EncryptorPage(),
    );
  }
}

class EncryptorPage extends StatefulWidget {
  const EncryptorPage({super.key});

  @override
  State<EncryptorPage> createState() => _EncryptorPageState();
}

class _EncryptorPageState extends State<EncryptorPage> {
  String? _filePath;
  String _fileName = '';
  int _fileSize = 0;
  int? _detectedVersion;

  String _algo = 'gcm';
  final _pw1 = TextEditingController();
  final _pw2 = TextEditingController();
  bool _obscure = true;

  bool _busy = false;
  double _progress = 0;
  String _progressText = '准备中…';

  String? _status;
  String _statusType = 'info';

  String? _resultPath;
  String _resultName = '';
  int _resultSize = 0;

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
    setState(() {
      _status = msg;
      _statusType = type;
    });
  }

  void _clearResult() {
    _resultPath = null;
    _resultName = '';
    _resultSize = 0;
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
      if (version == kVersionGcm) _algo = 'gcm';
      if (version == kVersionCtr) _algo = 'ctr';
    });
    if (version != null) {
      final algo = version == kVersionCtr ? 'AES-256-CTR（Cloudreve）' : 'AES-256-GCM';
      _showStatus('检测到加密文件（$algo），输入密码后点击「解密文件」');
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

  Future<String> _outputPath(String name) async {
    final dir = await getApplicationDocumentsDirectory();
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
    return candidate;
  }

  Future<void> _run(String type) async {
    if (_busy) return;
    if (_filePath == null) {
      _showStatus('请先选择文件', 'error');
      return;
    }
    final pw = _pw1.text;
    if (type == 'encrypt') {
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
    if (type == 'encrypt') {
      op = _algo == 'ctr' ? CryptoOp.encryptCtr : CryptoOp.encryptGcm;
      outName = '$_fileName.enc';
    } else {
      final v = _detectedVersion;
      if (v == kVersionCtr) {
        op = CryptoOp.decryptCtr;
      } else if (v == kVersionGcm) {
        op = CryptoOp.decryptGcm;
      } else {
        _showStatus('无法识别的加密文件', 'error');
        return;
      }
      outName = _decryptedName(_fileName);
    }

    setState(() {
      _busy = true;
      _status = null;
      _clearResult();
      _progress = 0;
      _progressText = '正在派生密钥…';
    });

    final watch = Stopwatch()..start();
    try {
      final out = await _outputPath(outName);
      await CryptoEngine.run(
        op: op,
        input: _filePath!,
        output: out,
        password: pw,
        onProgress: (p) {
          if (!mounted) return;
          setState(() {
            _progress = p;
            _progressText = '处理中… ${(p * 100).round()}%';
          });
        },
      );
      final size = await File(out).length();
      if (!mounted) return;
      setState(() {
        _resultPath = out;
        _resultName = outName;
        _resultSize = size;
      });
      watch.stop();
      _showStatus(
        type == 'encrypt'
            ? '加密完成，用时 ${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)} 秒，请妥善保管密码'
            : '解密完成，用时 ${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)} 秒',
        'success',
      );
    } catch (e) {
      _showStatus(e.toString().replaceFirst('CryptoException: ', ''), 'error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share() async {
    if (_resultPath == null) return;
    try {
      await Share.shareXFiles(
        [XFile(_resultPath!, mimeType: 'application/octet-stream')],
        text: _resultName,
      );
    } catch (e) {
      _showStatus('分享失败：$e', 'error');
    }
  }

  Future<void> _copyPath() async {
    if (_resultPath == null) return;
    await Clipboard.setData(ClipboardData(text: _resultPath!));
    _showStatus('已复制文件路径：$_resultPath', 'success');
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
    final isEncrypted = _detectedVersion != null;
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 540),
              child: Container(
                padding: const EdgeInsets.fromLTRB(22, 26, 22, 18),
                decoration: BoxDecoration(
                  color: kCard.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: kBorder),
                  boxShadow: const [
                    BoxShadow(color: Colors.black54, blurRadius: 70, offset: Offset(0, 24)),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: const [
                        Text('🔐', style: TextStyle(fontSize: 22)),
                        SizedBox(width: 9),
                        Text('文件加密',
                            style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                                color: kText,
                                letterSpacing: 0.3)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text('本地加密 · 文件不会上传 · 支持两种算法',
                        style: TextStyle(fontSize: 12.5, color: kMuted, height: 1.6)),
                    const SizedBox(height: 20),
                    _buildDropzone(),
                    if (_filePath != null) ...[
                      const SizedBox(height: 14),
                      _buildFileInfo(),
                    ],
                    const SizedBox(height: 18),
                    _buildAlgorithmField(),
                    const SizedBox(height: 18),
                    _buildPasswordField(),
                    if (!isEncrypted) ...[
                      const SizedBox(height: 16),
                      _buildConfirmField(),
                    ],
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: _btn(
                            label: '🔒 加密文件',
                            primary: !isEncrypted,
                            onTap: _busy ? null : () => _run('encrypt'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _btn(
                            label: '🔓 解密文件',
                            primary: isEncrypted,
                            onTap: _busy ? null : () => _run('decrypt'),
                          ),
                        ),
                      ],
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
                    if (_resultPath != null) ...[
                      const SizedBox(height: 16),
                      _buildResult(),
                    ],
                    const SizedBox(height: 18),
                    const Text('请牢记密码 · 密码丢失将无法恢复文件',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 11.5, color: kMuted)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDropzone() {
    return InkWell(
      onTap: _busy ? null : _pickFile,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 16),
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

  Widget _buildPasswordField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('密码',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: kMuted)),
        const SizedBox(height: 8),
        TextField(
          controller: _pw1,
          obscureText: _obscure,
          enabled: !_busy,
          style: const TextStyle(color: kText, fontSize: 14),
          decoration: InputDecoration(
            hintText: '输入密码（至少 $kMinPasswordLen 位）',
            hintStyle: const TextStyle(color: kMuted, fontSize: 13),
            filled: true,
            fillColor: const Color(0xFF1B222B),
            suffixIcon: IconButton(
              onPressed: () => setState(() => _obscure = !_obscure),
              icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility,
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

  Widget _buildConfirmField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('确认密码',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: kMuted)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: kBorder,
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text('仅加密时需要',
                  style: TextStyle(fontSize: 10.5, color: kMuted)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _pw2,
          obscureText: _obscure,
          enabled: !_busy,
          style: const TextStyle(color: kText, fontSize: 14),
          decoration: InputDecoration(
            hintText: '再次输入密码',
            hintStyle: const TextStyle(color: kMuted, fontSize: 13),
            filled: true,
            fillColor: const Color(0xFF1B222B),
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
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _btn(label: '📲 保存 / 分享', primary: true, onTap: _share)),
              const SizedBox(width: 10),
              Expanded(child: _btn(label: '📋 复制路径', primary: false, onTap: _copyPath)),
            ],
          ),
        ],
      ),
    );
  }
}
