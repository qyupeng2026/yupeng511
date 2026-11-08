import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../main.dart';
import '../services/app_settings.dart';
import '../services/record_store.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage>
    with AutomaticKeepAliveClientMixin {
  String _saveDir = '';
  bool _loadingDir = true;
  List<CryptoRecord> _encryptRecords = const [];
  List<CryptoRecord> _decryptRecords = const [];
  bool _loadingRecords = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadAll();
    RecordStore.revision.addListener(_onRecordsChanged);
  }

  @override
  void dispose() {
    RecordStore.revision.removeListener(_onRecordsChanged);
    super.dispose();
  }

  void _onRecordsChanged() {
    _loadRecords();
  }

  Future<void> _loadAll() async {
    await Future.wait([_loadDir(), _loadRecords()]);
  }

  Future<void> _loadDir() async {
    final dir = await AppSettings.saveDir();
    if (!mounted) return;
    setState(() {
      _saveDir = dir;
      _loadingDir = false;
    });
  }

  Future<void> _loadRecords() async {
    final all = await RecordStore.load();
    if (!mounted) return;
    setState(() {
      _encryptRecords = all.where((r) => r.type == RecordType.encrypt).toList();
      _decryptRecords = all.where((r) => r.type == RecordType.decrypt).toList();
      _loadingRecords = false;
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg, style: const TextStyle(fontSize: 13)),
        backgroundColor: kCard,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
  }

  Future<void> _pickSaveDir() async {
    final picked = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择文件保存目录',
    );
    if (picked == null || picked.isEmpty) return;
    final ok = await AppSettings.ensureWritable(picked);
    if (!ok) {
      _toast('该目录不可写，请重新选择');
      return;
    }
    await AppSettings.setSaveDir(picked);
    if (!mounted) return;
    setState(() => _saveDir = picked);
    _toast('保存目录已更新');
  }

  Future<void> _resetSaveDir() async {
    await AppSettings.resetSaveDir();
    await _loadDir();
    _toast('已恢复默认保存目录');
  }

  Future<void> _copySaveDir() async {
    await Clipboard.setData(ClipboardData(text: _saveDir));
    _toast('已复制保存目录路径');
  }

  void _openRecordsSheet(RecordType type) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kCard,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => _RecordsSheet(type: type),
    );
  }

  void _showAbout() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Row(
          children: const [
            Text('🔐', style: TextStyle(fontSize: 20)),
            SizedBox(width: 8),
            Text('关于我们',
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700, color: kText)),
          ],
        ),
        content: const SingleChildScrollView(
          child: Text(
            '文件加密是一款完全离线的本地文件加密工具。\n\n'
            '• 支持 AES-256-GCM 与 AES-256-CTR 两种算法\n'
            '• 兼容 Cloudreve 加密文件格式（FENC）\n'
            '• 全部计算在本机完成，文件不会上传\n'
            '• 大文件分块流式处理，内存占用恒定\n'
            '• 图片、视频解密后自动存入相册\n\n'
            '密码仅在本地用于密钥派生，请务必妥善保管；'
            '密码丢失后文件将无法恢复。',
            style: TextStyle(fontSize: 13, color: kMuted, height: 1.7),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了', style: TextStyle(color: kAccent)),
          ),
        ],
      ),
    );
  }

  void _showContact() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Row(
          children: const [
            Text('✉️', style: TextStyle(fontSize: 20)),
            SizedBox(width: 8),
            Text('联系我们',
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700, color: kText)),
          ],
        ),
        content: const Text(
          '使用中遇到问题或有功能建议，欢迎通过以下方式反馈：\n\n'
          '邮箱：support@monkeycode-ai.online\n\n'
          '反馈时请附上应用版本号与问题描述，便于我们快速定位。',
          style: TextStyle(fontSize: 13, color: kMuted, height: 1.7),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(
                  const ClipboardData(text: 'support@monkeycode-ai.online'));
              Navigator.pop(ctx);
              _toast('邮箱已复制');
            },
            child: const Text('复制邮箱', style: TextStyle(color: kAccent)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭', style: TextStyle(color: kMuted)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: RefreshIndicator(
          color: kAccent,
          backgroundColor: kCard,
          onRefresh: _loadAll,
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
            children: [
              _headerCard(),
              const SizedBox(height: 22),
              _sectionTitle('设置'),
              const SizedBox(height: 10),
              _card(
                children: [
                  _dirTile(),
                ],
              ),
              const SizedBox(height: 22),
              _sectionTitle('记录'),
              const SizedBox(height: 10),
              _card(
                children: [
                  _navTile(
                    icon: '🔒',
                    title: '加密记录',
                    subtitle: _loadingRecords
                        ? '加载中…'
                        : '共 ${_encryptRecords.length} 条',
                    onTap: () => _openRecordsSheet(RecordType.encrypt),
                  ),
                  const Divider(height: 1, color: kBorder, indent: 56),
                  _navTile(
                    icon: '🔓',
                    title: '解密记录',
                    subtitle: _loadingRecords
                        ? '加载中…'
                        : '共 ${_decryptRecords.length} 条',
                    onTap: () => _openRecordsSheet(RecordType.decrypt),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              _sectionTitle('其他'),
              const SizedBox(height: 10),
              _card(
                children: [
                  _navTile(
                    icon: 'ℹ️',
                    title: '关于我们',
                    subtitle: '版本 1.2.0',
                    onTap: _showAbout,
                  ),
                  const Divider(height: 1, color: kBorder, indent: 56),
                  _navTile(
                    icon: '✉️',
                    title: '联系我们',
                    subtitle: '问题反馈与建议',
                    onTap: _showContact,
                  ),
                ],
              ),
              const SizedBox(height: 26),
              const Center(
                child: Text('本地加密 · 数据不出设备',
                    style: TextStyle(fontSize: 11.5, color: kMuted)),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  Widget _headerCard() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1E2433), Color(0xFF161B22)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kBorder),
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: kAccent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Text('🔐', style: TextStyle(fontSize: 24)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('文件加密',
                    style: TextStyle(
                        fontSize: 16.5,
                        fontWeight: FontWeight.w700,
                        color: kText)),
                const SizedBox(height: 5),
                Text(
                  '已处理 ${_encryptRecords.length + _decryptRecords.length} 个文件',
                  style: const TextStyle(fontSize: 12.5, color: kMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(left: 4),
        child: Text(text,
            style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: kMuted,
                letterSpacing: 0.5)),
      );

  Widget _card({required List<Widget> children}) {
    return Container(
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kBorder),
      ),
      child: Column(children: children),
    );
  }

  Widget _dirTile() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('📁', style: TextStyle(fontSize: 18)),
              const SizedBox(width: 12),
              const Expanded(
                child: Text('保存目录',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: kText)),
              ),
              if (!_loadingDir)
                TextButton(
                  onPressed: _pickSaveDir,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: const Size(0, 32),
                  ),
                  child: const Text('更改',
                      style: TextStyle(fontSize: 13, color: kAccent)),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF1B222B),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: kBorder),
            ),
            child: Text(
              _loadingDir ? '读取中…' : _saveDir,
              style: const TextStyle(fontSize: 12, color: Color(0xFFA5B4FC)),
            ),
          ),
          const SizedBox(height: 8),
          const Text('加密产物与非图片/视频文件将保存到此目录；图片、视频完成后会存入相册。',
              style: TextStyle(fontSize: 11.5, color: kMuted, height: 1.5)),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _loadingDir ? null : _copySaveDir,
                  icon: const Icon(Icons.copy, size: 15),
                  label: const Text('复制路径', style: TextStyle(fontSize: 12.5)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kMuted,
                    side: const BorderSide(color: kBorder),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(9)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _loadingDir ? null : _resetSaveDir,
                  icon: const Icon(Icons.restore, size: 15),
                  label: const Text('恢复默认', style: TextStyle(fontSize: 12.5)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kMuted,
                    side: const BorderSide(color: kBorder),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(9)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _navTile({
    required String icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Text(icon, style: const TextStyle(fontSize: 18)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: kText)),
                  const SizedBox(height: 3),
                  Text(subtitle,
                      style: const TextStyle(fontSize: 11.5, color: kMuted)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, size: 20, color: kMuted),
          ],
        ),
      ),
    );
  }
}

class _RecordsSheet extends StatefulWidget {
  final RecordType type;
  const _RecordsSheet({required this.type});

  @override
  State<_RecordsSheet> createState() => _RecordsSheetState();
}

class _RecordsSheetState extends State<_RecordsSheet> {
  List<CryptoRecord> _records = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    RecordStore.revision.addListener(_load);
  }

  @override
  void dispose() {
    RecordStore.revision.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final all = await RecordStore.load();
    if (!mounted) return;
    setState(() {
      _records = all.where((r) => r.type == widget.type).toList();
      _loading = false;
    });
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

  String _fmtTime(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  Future<void> _clearAll() async {
    final label = widget.type == RecordType.encrypt ? '加密' : '解密';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('清空$label记录',
            style: const TextStyle(fontSize: 16, color: kText)),
        content: Text('将删除全部$label记录，此操作不可恢复。',
            style: const TextStyle(fontSize: 13.5, color: kMuted, height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: kMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空', style: TextStyle(color: kDanger)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final all = await RecordStore.load();
    await RecordStore.replaceAll(
      all.where((r) => r.type != widget.type).toList(),
    );
    await _load();
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('$label记录已清空', style: const TextStyle(fontSize: 13)),
        backgroundColor: kCard,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final isEncrypt = widget.type == RecordType.encrypt;
    final label = isEncrypt ? '加密记录' : '解密记录';
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      builder: (ctx, scroll) => Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: kBorder,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 10, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text('$label（${_records.length}）',
                      style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: kText)),
                ),
                TextButton(
                  onPressed: _records.isEmpty ? null : _clearAll,
                  child: const Text('清空',
                      style: TextStyle(fontSize: 13, color: kDanger)),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: kBorder),
          Expanded(
            child: _loading
                ? const Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: kAccent),
                    ),
                  )
                : _records.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(isEncrypt ? '🔒' : '🔓',
                                style: const TextStyle(fontSize: 34)),
                            const SizedBox(height: 12),
                            Text('暂无$label',
                                style:
                                    const TextStyle(fontSize: 13, color: kMuted)),
                          ],
                        ),
                      )
                    : ListView.separated(
                        controller: scroll,
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        itemCount: _records.length,
                        separatorBuilder: (_, __) => const Divider(
                            height: 1, color: kBorder, indent: 18),
                        itemBuilder: (_, i) => _tile(_records[i]),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _tile(CryptoRecord r) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: kAccent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text(r.type == RecordType.encrypt ? '🔒' : '🔓',
                style: const TextStyle(fontSize: 15)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13.5, color: kText)),
                const SizedBox(height: 4),
                Text('${r.algorithm} · ${_fmt(r.size)}',
                    style: const TextStyle(fontSize: 11.5, color: kMuted)),
                const SizedBox(height: 2),
                Text(_fmtTime(r.time),
                    style: const TextStyle(fontSize: 11, color: kMuted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
