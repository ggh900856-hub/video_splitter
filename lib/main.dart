import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_video/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_video/return_code.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

const kBg = Color(0xFF0A1128);
const kSurface = Color(0xFF1C2541);
const kAccent = Color(0xFF00B4D8);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  runApp(const SplitterApp());
}

// ───────────────────────── App ─────────────────────────

class SplitterApp extends StatelessWidget {
  const SplitterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'مجزئ الفيديو',
      locale: const Locale('ar'),
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: kBg,
        colorScheme: const ColorScheme.dark(primary: kAccent, surface: kSurface),
      ),
      builder: (context, child) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: const HomePage(),
    );
  }
}

// ───────────────────── Helpers / Models ─────────────────────

class FolderInfo {
  final Directory dir;
  final String name;
  final int count;
  final File? cover;
  final DateTime modified;

  FolderInfo({
    required this.dir,
    required this.name,
    required this.count,
    required this.cover,
    required this.modified,
  });
}

String cleanFolderName(String path) {
  final raw = path.split('/').last;
  final i = raw.lastIndexOf('_');
  return i > 0 ? raw.substring(0, i) : raw;
}

String formatSize(int bytes) {
  final mb = bytes / (1024 * 1024);
  return '${mb.toStringAsFixed(1)} MB';
}

/// يولّد صور مصغرة للمقاطع عن طريق FFmpeg ويخزنها في مجلد .thumbs
/// بالترتيب (واحدة ورا التانية) عشان ما نضغطش على الموبايل.
class ThumbService {
  static final Map<String, Future<File?>> _cache = {};
  static Future<void> _queue = Future.value();

  static File thumbFileFor(File video) {
    final name = video.path.split('/').last.replaceAll('.mp4', '.jpg');
    return File('${video.parent.path}/.thumbs/$name');
  }

  static Future<File?> get(File video) {
    return _cache.putIfAbsent(video.path, () => _generate(video));
  }

  static void forget(File video) {
    _cache.remove(video.path);
    try {
      final t = thumbFileFor(video);
      if (t.existsSync()) t.deleteSync();
    } catch (_) {}
  }

  static Future<File?> _generate(File video) {
    final completer = Completer<File?>();
    _queue = _queue.then((_) async {
      try {
        completer.complete(await _run(video));
      } catch (_) {
        completer.complete(null);
      }
    });
    return completer.future;
  }

  static Future<File?> _run(File video) async {
    final out = thumbFileFor(video);
    final dir = out.parent;
    if (!await dir.exists()) await dir.create(recursive: true);
    if (await out.exists() && await out.length() > 0) return out;

    for (final ss in ['0.5', '0']) {
      final session = await FFmpegKit.execute(
        '-y -ss $ss -i "${video.path}" -frames:v 1 -vf scale=360:-2 -q:v 4 "${out.path}"',
      );
      final code = await session.getReturnCode();
      if (ReturnCode.isSuccess(code) && await out.exists() && await out.length() > 0) {
        return out;
      }
    }
    return null;
  }
}

class VideoThumb extends StatelessWidget {
  final File video;
  const VideoThumb({super.key, required this.video});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File?>(
      future: ThumbService.get(video),
      builder: (context, snap) {
        final f = snap.data;
        if (f != null) {
          return Image.file(f, fit: BoxFit.cover, gaplessPlayback: true);
        }
        return Container(
          color: Colors.black26,
          child: Center(
            child: snap.connectionState == ConnectionState.done
                ? const Icon(Icons.movie, color: Colors.white24, size: 32)
                : const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: kAccent),
                  ),
          ),
        );
      },
    );
  }
}

// ───────────────────────── Home ─────────────────────────

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _picker = ImagePicker();
  final _customTimeController = TextEditingController();
  bool _isProcessing = false;
  double _progress = 0;
  String _status = 'جاهز للاستخدام';
  List<FolderInfo> _folders = [];

  @override
  void initState() {
    super.initState();
    _initForegroundTask();
    _requestNotificationPermission();
    _loadSavedFolders();
  }

  @override
  void dispose() {
    _customTimeController.dispose();
    super.dispose();
  }

  void _initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'splitter_background_channel',
        channelName: 'خدمة تجزئة الفيديو',
        channelDescription: 'تضمن استمرار التقسيم في الخلفية على أندرويد 15',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true,
      ),
    );
  }

  Future<void> _requestNotificationPermission() async {
    final perm = await FlutterForegroundTask.checkNotificationPermission();
    if (perm != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
  }

  Future<void> _loadSavedFolders() async {
    final dir = await getApplicationDocumentsDirectory();
    final root = Directory('${dir.path}/SplitVideos');
    if (!await root.exists()) {
      if (mounted) setState(() => _folders = []);
      return;
    }

    final infos = <FolderInfo>[];
    await for (final e in root.list()) {
      if (e is! Directory) continue;
      final files = e
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.mp4'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      infos.add(FolderInfo(
        dir: e,
        name: cleanFolderName(e.path),
        count: files.length,
        cover: files.isEmpty ? null : files.first,
        modified: e.statSync().modified,
      ));
    }
    infos.sort((a, b) => b.modified.compareTo(a.modified));

    if (!mounted) return;
    setState(() => _folders = infos);
  }

  Future<void> _startSplitting(int seconds) async {
    final XFile? video = await _picker.pickVideo(source: ImageSource.gallery);
    if (video == null) return;

    setState(() {
      _isProcessing = true;
      _progress = 0;
      _status = 'جاري قراءة الفيديو…';
    });

    // مدة الفيديو الكلية عشان نحسب النسبة المئوية
    int totalMs = 0;
    try {
      final probe = VideoPlayerController.file(File(video.path));
      await probe.initialize();
      totalMs = probe.value.duration.inMilliseconds;
      await probe.dispose();
    } catch (_) {}

    await FlutterForegroundTask.startService(
      notificationTitle: 'جاري تجزئة الفيديو الآن',
      notificationText: 'يرجى الانتظار، المعالجة مستمرة في الخلفية...',
    );

    try {
      final appDir = await getApplicationDocumentsDirectory();
      final originalName = video.name.split('.').first;
      final folderName = '${originalName}_${DateTime.now().millisecondsSinceEpoch}';
      final outputFolder = Directory('${appDir.path}/SplitVideos/$folderName');
      await outputFolder.create(recursive: true);

      final outputPattern = '${outputFolder.path}/part_%03d.mp4';
      final cmd = '-i "${video.path}" -c copy -map 0 -f segment '
          '-segment_time $seconds -reset_timestamps 1 "$outputPattern"';

      await FFmpegKit.executeAsync(
        cmd,
        (session) async {
          final code = await session.getReturnCode();
          await FlutterForegroundTask.stopService();
          if (!mounted) return;

          final ok = ReturnCode.isSuccess(code);
          setState(() {
            _isProcessing = false;
            _status = ok ? 'تم تقسيم الفيديو وحفظه في المكتبة!' : 'فشلت عملية تقسيم المقطع';
          });
          if (ok) {
            await _loadSavedFolders();
            if (mounted) _showFolderContents(outputFolder, cleanFolderName(outputFolder.path));
          }
        },
        null,
        (statistics) {
          if (totalMs <= 0 || !mounted) return;
          final p = (statistics.getTime() / totalMs).clamp(0.0, 1.0).toDouble();
          setState(() {
            _progress = p;
            _status = 'جاري التقسيم… ${(p * 100).toStringAsFixed(0)}%';
          });
        },
      );
    } catch (e) {
      await FlutterForegroundTask.stopService();
      if (!mounted) return;
      setState(() {
        _isProcessing = false;
        _status = 'حدث خطأ: $e';
      });
    }
  }

  void _showFolderContents(Directory folder, String title) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => FolderDetailsPage(folder: folder, title: title)),
    ).then((_) => _loadSavedFolders());
  }

  Future<void> _deleteFolder(FolderInfo f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kSurface,
        title: const Text('حذف المجلد', style: TextStyle(fontSize: 16)),
        content: Text('هتتحذف كل مقاطع "${f.name}" نهائياً. متأكد؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('حذف', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await f.dir.delete(recursive: true);
    } catch (_) {}
    await _loadSavedFolders();
  }

  void _showCustomTimeDialog() {
    final messenger = ScaffoldMessenger.of(context);
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: kSurface,
          title: const Text('تحديد وقت مخصص', style: TextStyle(fontSize: 16)),
          content: TextField(
            controller: _customTimeController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              hintText: 'أدخل عدد الثواني (مثال: 45)',
              focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: kAccent)),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('إلغاء', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: kAccent),
              onPressed: () {
                final seconds = int.tryParse(_customTimeController.text) ?? 0;
                Navigator.pop(ctx);
                if (seconds > 0) {
                  _startSplitting(seconds);
                } else {
                  messenger.showSnackBar(
                    const SnackBar(content: Text('يرجى إدخال رقم صحيح أكبر من صفر')),
                  );
                }
              },
              child: const Text('تأكيد', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('مجزئ الفيديو الاحترافي'),
        centerTitle: true,
        backgroundColor: kBg,
        elevation: 0,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildTimeButton('15 ثانية', () => _startSplitting(15)),
                _buildTimeButton('30 ثانية', () => _startSplitting(30)),
                _buildTimeButton('60 ثانية', () => _startSplitting(60)),
              ],
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: kAccent,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: _isProcessing ? null : _showCustomTimeDialog,
              icon: const Icon(Icons.av_timer, color: Colors.white),
              label: const Text(
                'تقسيم بوقت مخصص (Custom)',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 20),
            if (_isProcessing) ...[
              LinearProgressIndicator(
                value: _progress > 0 ? _progress : null,
                color: kAccent,
                backgroundColor: Colors.white12,
                minHeight: 6,
              ),
              const SizedBox(height: 10),
            ],
            Center(child: Text(_status, style: const TextStyle(color: Colors.white54, fontSize: 13))),
            const Divider(height: 40, color: Colors.white12),
            const Text(
              'مكتبة المجلدات المحفوظة:',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: kAccent),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: _folders.isEmpty
                  ? const Center(
                      child: Text(
                        'المكتبة فارغة، قم بتجزئة فيديو لتظهر ملفاتك هنا.',
                        style: TextStyle(color: Colors.grey, fontSize: 13),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _folders.length,
                      itemBuilder: (context, index) => _buildFolderCard(_folders[index]),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFolderCard(FolderInfo f) {
    return Card(
      color: kSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.symmetric(vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _showFolderContents(f.dir, f.name),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 76,
                  height: 76,
                  child: f.cover != null
                      ? VideoThumb(video: f.cover!)
                      : Container(
                          color: Colors.black26,
                          child: const Icon(Icons.folder, color: Colors.amber, size: 32),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      f.name,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text('${f.count} مقطع', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, color: Colors.white54),
                color: kSurface,
                onSelected: (v) {
                  if (v == 'delete') _deleteFolder(f);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'delete', child: Text('حذف المجلد')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTimeButton(String label, VoidCallback onPressed) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: kSurface,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      onPressed: _isProcessing ? null : onPressed,
      child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 13)),
    );
  }
}

// ───────────────────── Folder details ─────────────────────

class FolderDetailsPage extends StatefulWidget {
  final Directory folder;
  final String title;
  const FolderDetailsPage({super.key, required this.folder, required this.title});

  @override
  State<FolderDetailsPage> createState() => _FolderDetailsPageState();
}

class _FolderDetailsPageState extends State<FolderDetailsPage> {
  List<File> _files = [];
  final Map<String, int> _sizes = {};
  final Set<String> _selected = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _files = _readFiles();
    _selected.addAll(_files.map((f) => f.path));
  }

  List<File> _readFiles() {
    final list = widget.folder
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.mp4'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    _sizes.clear();
    for (final f in list) {
      try {
        _sizes[f.path] = f.lengthSync();
      } catch (_) {}
    }
    return list;
  }

  List<File> get _selectedFiles => _files.where((f) => _selected.contains(f.path)).toList();

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _toggle(String path) {
    setState(() {
      if (!_selected.add(path)) _selected.remove(path);
    });
  }

  void _toggleAll() {
    setState(() {
      if (_selected.length == _files.length) {
        _selected.clear();
      } else {
        _selected.addAll(_files.map((f) => f.path));
      }
    });
  }

  Future<void> _saveSelectedToGallery() async {
    final selected = _selectedFiles;
    if (selected.isEmpty) {
      _snack('يرجى تحديد مقطع واحد على الأقل');
      return;
    }

    setState(() => _busy = true);
    try {
      if (!await Gal.hasAccess(toAlbum: true)) {
        final granted = await Gal.requestAccess(toAlbum: true);
        if (!granted) {
          _snack('لازم توافق على إذن الوصول للمعرض عشان نحفظ المقاطع');
          return;
        }
      }
      for (final f in selected) {
        await Gal.putVideo(f.path, album: 'VideoSplitter');
      }
      _snack('تم حفظ ${selected.length} مقطع في المعرض (ألبوم VideoSplitter)');
    } catch (e) {
      _snack('حدث خطأ أثناء الحفظ: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _shareSelectedFiles() async {
    final selected = _selectedFiles;
    if (selected.isEmpty) {
      _snack('يرجى تحديد مقطع واحد على الأقل للمشاركة');
      return;
    }
    await Share.shareXFiles(
      selected.map((f) => XFile(f.path)).toList(),
      text: 'المقاطع المقسمة الخاصة بي',
    );
  }

  Future<void> _deleteSelected() async {
    final selected = _selectedFiles;
    if (selected.isEmpty) {
      _snack('يرجى تحديد مقطع واحد على الأقل للحذف');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kSurface,
        title: const Text('حذف المقاطع', style: TextStyle(fontSize: 16)),
        content: Text('هتتحذف ${selected.length} مقطع نهائياً. متأكد؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('حذف', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (ok != true) return;

    for (final f in selected) {
      try {
        ThumbService.forget(f);
        await f.delete();
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _files = _readFiles();
      _selected.removeWhere((p) => !_files.any((f) => f.path == p));
    });
  }

  void _openPlayer(int index) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => VideoPlayerPage(files: _files, index: index)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final allSelected = _files.isNotEmpty && _selected.length == _files.length;
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        backgroundColor: kBg,
        actions: [
          IconButton(
            tooltip: allSelected ? 'إلغاء التحديد' : 'تحديد الكل',
            icon: Icon(allSelected ? Icons.deselect : Icons.select_all),
            onPressed: _files.isEmpty ? null : _toggleAll,
          ),
          IconButton(
            tooltip: 'حذف المحدد',
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
            onPressed: _files.isEmpty ? null : _deleteSelected,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _files.isEmpty
                ? const Center(child: Text('لا توجد مقاطع', style: TextStyle(color: Colors.grey)))
                : GridView.builder(
                    padding: const EdgeInsets.all(12),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      childAspectRatio: 0.9,
                    ),
                    itemCount: _files.length,
                    itemBuilder: (context, index) => _buildTile(index),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.amber,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: _busy ? null : _saveSelectedToGallery,
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                          )
                        : const Icon(Icons.save_alt, color: Colors.black),
                    label: const Text(
                      'حفظ بالمعرض',
                      style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kAccent,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: _busy ? null : _shareSelectedFiles,
                    icon: const Icon(Icons.share, color: Colors.white),
                    label: const Text(
                      'مشاركة المحدَد',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTile(int index) {
    final file = _files[index];
    final name = file.path.split('/').last;
    final selected = _selected.contains(file.path);

    return GestureDetector(
      onTap: () => _openPlayer(index),
      onLongPress: () => _toggle(file.path),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: kSurface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: selected ? kAccent : Colors.transparent, width: 2),
        ),
        child: Column(
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  VideoThumb(video: file),
                  Container(color: Colors.black26),
                  const Center(
                    child: Icon(Icons.play_circle_fill, size: 46, color: Colors.white70),
                  ),
                  Positioned(
                    top: 2,
                    right: 2,
                    child: Checkbox(
                      value: selected,
                      activeColor: kAccent,
                      side: const BorderSide(color: Colors.white, width: 1.5),
                      onChanged: (_) => _toggle(file.path),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      name,
                      style: const TextStyle(fontSize: 12),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textDirection: TextDirection.ltr,
                    ),
                  ),
                  Text(
                    formatSize(_sizes[file.path] ?? 0),
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────── Advanced player ─────────────────────

class VideoPlayerPage extends StatefulWidget {
  final List<File> files;
  final int index;
  const VideoPlayerPage({super.key, required this.files, required this.index});

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  VideoPlayerController? _c;
  late int _index;
  bool _ready = false;
  bool _error = false;
  bool _showControls = true;
  bool _advancing = false;
  bool _landscape = false;
  double _speed = 1.0;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _index = widget.index;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(_index));
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _c?.removeListener(_onTick);
    _c?.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  Future<void> _load(int i) async {
    final old = _c;
    old?.removeListener(_onTick);
    if (mounted) {
      setState(() {
        _c = null;
        _ready = false;
        _error = false;
        _index = i;
      });
    }
    await old?.dispose();

    final c = VideoPlayerController.file(widget.files[i]);
    try {
      await c.initialize();
    } catch (_) {
      await c.dispose();
      if (mounted) setState(() => _error = true);
      return;
    }
    if (!mounted) {
      await c.dispose();
      return;
    }
    await c.setPlaybackSpeed(_speed);
    c.addListener(_onTick);
    await c.play();
    setState(() {
      _c = c;
      _ready = true;
    });
    _scheduleHide();
  }

  void _onTick() {
    final c = _c;
    if (c == null || !mounted) return;
    final v = c.value;
    if (v.isInitialized &&
        v.duration > Duration.zero &&
        v.position >= v.duration &&
        !v.isPlaying &&
        _index < widget.files.length - 1 &&
        !_advancing) {
      _advancing = true;
      _load(_index + 1).whenComplete(() => _advancing = false);
      return;
    }
    setState(() {});
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && (_c?.value.isPlaying ?? false)) {
        setState(() => _showControls = false);
      }
    });
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _scheduleHide();
  }

  Future<void> _togglePlay() async {
    final c = _c;
    if (c == null) return;
    if (c.value.isPlaying) {
      await c.pause();
    } else {
      if (c.value.position >= c.value.duration) await c.seekTo(Duration.zero);
      await c.play();
    }
    _scheduleHide();
  }

  Future<void> _seekBy(int seconds) async {
    final c = _c;
    if (c == null) return;
    final target = c.value.position + Duration(seconds: seconds);
    final max = c.value.duration;
    await c.seekTo(target < Duration.zero ? Duration.zero : (target > max ? max : target));
    _scheduleHide();
  }

  void _toggleOrientation() {
    _landscape = !_landscape;
    SystemChrome.setPreferredOrientations(
      _landscape
          ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
          : [DeviceOrientation.portraitUp],
    );
    setState(() {});
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final name = widget.files[_index].path.split('/').last;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: [
            // الفيديو
            Positioned.fill(
              child: Center(
                child: _error
                    ? const Text('تعذر تشغيل المقطع', style: TextStyle(color: Colors.white70))
                    : (_ready && c != null)
                        ? AspectRatio(
                            aspectRatio: c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio,
                            child: VideoPlayer(c),
                          )
                        : const CircularProgressIndicator(color: kAccent),
              ),
            ),

            // لمسة واحدة: إظهار/إخفاء — لمستين: ±10 ثواني
            Positioned.fill(
              child: Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: _toggleControls,
                      onDoubleTap: () => _seekBy(-10),
                    ),
                  ),
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: _toggleControls,
                      onDoubleTap: () => _seekBy(10),
                    ),
                  ),
                ],
              ),
            ),

            if (_showControls) ...[
              _buildTopBar(name),
              if (_ready && c != null) _buildCenterControls(c),
              if (_ready && c != null) _buildBottomBar(c),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(String name) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () => Navigator.pop(context),
              ),
              Expanded(
                child: Text(
                  '$name  •  ${_index + 1}/${widget.files.length}',
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              PopupMenuButton<double>(
                tooltip: 'السرعة',
                color: kSurface,
                initialValue: _speed,
                onSelected: (s) async {
                  _speed = s;
                  await _c?.setPlaybackSpeed(s);
                  if (mounted) setState(() {});
                },
                itemBuilder: (_) => [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
                    .map((s) => PopupMenuItem(value: s, child: Text('${s}x')))
                    .toList(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Text(
                    '${_speed}x',
                    style: const TextStyle(color: kAccent, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              IconButton(
                icon: Icon(
                  _landscape ? Icons.stay_current_portrait : Icons.screen_rotation,
                  color: Colors.white,
                ),
                onPressed: _toggleOrientation,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCenterControls(VideoPlayerController c) {
    final hasPrev = _index > 0;
    final hasNext = _index < widget.files.length - 1;
    return Positioned.fill(
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              iconSize: 36,
              icon: Icon(Icons.skip_previous, color: hasPrev ? Colors.white : Colors.white24),
              onPressed: hasPrev ? () => _load(_index - 1) : null,
            ),
            IconButton(
              iconSize: 36,
              icon: const Icon(Icons.replay_10, color: Colors.white),
              onPressed: () => _seekBy(-10),
            ),
            IconButton(
              iconSize: 68,
              icon: Icon(
                c.value.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
                color: Colors.white,
              ),
              onPressed: _togglePlay,
            ),
            IconButton(
              iconSize: 36,
              icon: const Icon(Icons.forward_10, color: Colors.white),
              onPressed: () => _seekBy(10),
            ),
            IconButton(
              iconSize: 36,
              icon: Icon(Icons.skip_next, color: hasNext ? Colors.white : Colors.white24),
              onPressed: hasNext ? () => _load(_index + 1) : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar(VideoPlayerController c) {
    final total = c.value.duration.inMilliseconds.toDouble();
    final pos = c.value.position.inMilliseconds.toDouble().clamp(0.0, total <= 0 ? 1.0 : total).toDouble();

    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Row(
              children: [
                Text(_fmt(c.value.position), style: const TextStyle(color: Colors.white, fontSize: 12)),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      activeTrackColor: kAccent,
                      inactiveTrackColor: Colors.white24,
                      thumbColor: kAccent,
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                    ),
                    child: Slider(
                      min: 0,
                      max: total <= 0 ? 1 : total,
                      value: pos,
                      onChangeStart: (_) => _hideTimer?.cancel(),
                      onChanged: (v) => c.seekTo(Duration(milliseconds: v.toInt())),
                      onChangeEnd: (_) => _scheduleHide(),
                    ),
                  ),
                ),
                Text(_fmt(c.value.duration), style: const TextStyle(color: Colors.white, fontSize: 12)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}