import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_video/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_video/return_code.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  runApp(const SplitterApp());
}

class SplitterApp extends StatelessWidget {
  const SplitterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'مجزئ الفيديو',
      locale: const Locale('ar'),
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0A1128),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00B4D8),
          surface: Color(0xFF1C2541),
        ),
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

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _picker = ImagePicker();
  final _customTimeController = TextEditingController();
  bool _isProcessing = false;
  String _status = 'جاهز للاستخدام';
  List<Directory> _savedFolders = [];

  @override
  void initState() {
    super.initState();
    _initForegroundTask();
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

  Future<void> _loadSavedFolders() async {
    final dir = await getApplicationDocumentsDirectory();
    final splitterDir = Directory('${dir.path}/SplitVideos');
    if (await splitterDir.exists()) {
      final entities = splitterDir.listSync();
      setState(() {
        _savedFolders = entities.whereType<Directory>().toList();
      });
    }
  }

  Future<void> _startSplitting(int seconds) async {
    final XFile? video = await _picker.pickVideo(source: ImageSource.gallery);
    if (video == null) return;

    setState(() {
      _isProcessing = true;
      _status = 'جاري بدء التجزئة في الخلفية بأمان…';
    });

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

      final outputPathPattern = "${outputFolder.path}/part_%03d.mp4";
      final ffmpegCommand = "-i ${video.path} -c copy -map 0 -f segment -segment_time $seconds -reset_timestamps 1 $outputPathPattern";

      await FFmpegKit.executeAsync(ffmpegCommand, (session) async {
        final returnCode = await session.getReturnCode();
        await FlutterForegroundTask.stopService();

        if (!mounted) return;

        setState(() {
          _isProcessing = false;
        });

        if (ReturnCode.isSuccess(returnCode)) {
          setState(() {
            _status = 'تم تقسيم الفيديو وحفظه في المكتبة!';
          });
          _loadSavedFolders();
          _showFolderContents(outputFolder);
        } else {
          setState(() {
            _status = 'فشلت عملية تقسيم المقطع';
          });
        }
      });
    } catch (e) {
      await FlutterForegroundTask.stopService();
      setState(() {
        _isProcessing = false;
        _status = 'حدث خطأ: $e';
      });
    }
  }

  void _showFolderContents(Directory folder) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => FolderDetailsPage(folder: folder)),
    ).then((_) => _loadSavedFolders());
  }

  void _showCustomTimeDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1C2541),
          title: const Text('تحديد وقت مخصص', style: TextStyle(fontSize: 16)),
          content: TextField(
            controller: _customTimeController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              hintText: 'أدخل عدد الثواني (مثال: 45)',
              focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF00B4D8))),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('إلغاء', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00B4D8)),
              onPressed: () {
                final seconds = int.tryParse(_customTimeController.text) ?? 0;
                Navigator.pop(context);
                if (seconds > 0) {
                  _startSplitting(seconds);
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
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
        backgroundColor: const Color(0xFF0A1128),
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
                backgroundColor: const Color(0xFF00B4D8),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: _isProcessing ? null : _showCustomTimeDialog,
              icon: const Icon(Icons.av_timer, color: Colors.white),
              label: const Text('تقسيم بوقت مخصص (Custom)', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 20),
            if (_isProcessing) ...[
              const Center(child: CircularProgressIndicator(color: Color(0xFF00B4D8))),
              const SizedBox(height: 10),
            ],
            Center(child: Text(_status, style: const TextStyle(color: Colors.white54, fontSize: 13))),
            const Divider(height: 40, color: Colors.white12),
            const Text(
              'مكتبة المجلدات المحفوظة:',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF00B4D8)),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: _savedFolders.isEmpty
                  ? const Center(child: Text('المكتبة فارغة، قم بتجزئة فيديو لتظهر ملفاتك هنا.', style: TextStyle(color: Colors.grey, fontSize: 13)))
                  : ListView.builder(
                      itemCount: _savedFolders.length,
                      itemBuilder: (context, index) {
                        final folder = _savedFolders[index];
                        final rawFolderName = folder.path.split('/').last;
                        final cleanName = rawFolderName.contains('_') ? rawFolderName.substring(0, rawFolderName.lastIndexOf('_')) : rawFolderName;
                        final filesCount = folder.listSync().length;
                        return Card(
                          color: Theme.of(context).colorScheme.surface,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          margin: const EdgeInsets.symmetric(vertical: 6),
                          child: ListTile(
                            leading: const Icon(Icons.folder, size: 36, color: Colors.amber),
                            title: Text(cleanName, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text('$filesCount مقطع مقسم', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                            trailing: const Icon(Icons.arrow_forward_ios, size: 14, color: Colors.white30),
                            onTap: () => _showFolderContents(folder),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTimeButton(String label, VoidCallback onPressed) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF1C2541),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      onPressed: _isProcessing ? null : onPressed,
      child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 13)),
    );
  }
}

class FolderDetailsPage extends StatefulWidget {
  final Directory folder;
  const FolderDetailsPage({super.key, required this.folder});

  @override
  State<FolderDetailsPage> createState() => _FolderDetailsPageState();
}

class _FolderDetailsPageState extends State<FolderDetailsPage> {
  List<FileSystemEntity> _files = [];
  final Map<String, bool> _selectedFiles = {};

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  void _loadFiles() {
    final entities = widget.folder.listSync().whereType<File>().toList();
    entities.sort((a, b) => a.path.compareTo(b.path));
    setState(() {
      _files = entities;
      for (var file in _files) {
        if (!_selectedFiles.containsKey(file.path)) {
          _selectedFiles[file.path] = true;
        }
      }
    });
  }

  Future<void> _saveSelectedToGallery() async {
    final selectedPaths = _files.where((f) => _selectedFiles[f.path] == true).map((f) => f.path).toList();
    if (selectedPaths.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('يرجى تحديد مقطع واحد على الأقل')));
      return;
    }

    try {
      final Directory galleryDir = Directory('/storage/emulated/0/Download');
      if (await galleryDir.exists()) {
        for (var path in selectedPaths) {
          final file = File(path);
          final name = path.split('/').last;
          await file.copy('${galleryDir.path}/$name');
        }
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم حفظ المقاطع المحددة في مجلد Download بالمعرض!')));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعذر الوصول لمجلد التنزيلات بالهاتف')));
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('حدث خطأ أثناء الحفظ: $e')));
    }
  }

  void _shareSelectedFiles() {
    final selectedXFiles = _files.where((f) => _selectedFiles[f.path] == true).map((f) => XFile(f.path)).toList();
    if (selectedXFiles.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('يرجى تحديد مقطع واحد على الأقل للمشاركة')));
      return;
    }
    Share.shareXFiles(selectedXFiles, text: 'المقاطع المقسمة الخاصة بي');
  }

  void _previewVideo(File file) {
    showDialog(
      context: context,
      builder: (context) => VideoPlayerDialog(file: file),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A1128),
      appBar: AppBar(title: const Text('المقاطع الناتجة'), backgroundColor: const Color(0xFF0A1128)),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              itemCount: _files.length,
              itemBuilder: (context, index) {
                final file = _files[index] as File;
                final name = file.path.split('/').last;
                return CheckboxListTile(
                  title: Text(name, style: const TextStyle(fontSize: 14)),
                  secondary: IconButton(
                    icon: const Icon(Icons.play_circle_fill, color: Color(0xFF00B4D8), size: 30),
                    onPressed: () => _previewVideo(file),
                  ),
                  value: _selectedFiles[file.path],
                  activeColor: const Color(0xFF00B4D8),
                  onChanged: (bool? val) {
                    setState(() {
                      _selectedFiles[file.path] = val ?? false;
                    });
                  },
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.amber, padding: const EdgeInsets.symmetric(vertical: 14)),
                    onPressed: _saveSelectedToGallery,
                    icon: const Icon(Icons.save_alt, color: Colors.black),
                    label: const Text('حفظ بالمعرض', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00B4D8), padding: const EdgeInsets.symmetric(vertical: 14)),
                    onPressed: _shareSelectedFiles,
                    icon: const Icon(Icons.share, color: Colors.white),
                    label: const Text('مشاركة المحدَد', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class VideoPlayerDialog extends StatefulWidget {
  final File file;
  const VideoPlayerDialog({super.key, required this.file});

  @override
  State<VideoPlayerDialog> createState() => _VideoPlayerDialogState();
}

class _VideoPlayerDialogState extends State<VideoPlayerDialog> {
  late VideoPlayerController _controller;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(widget.file)..initialize().then((_) {
      setState(() {
        _initialized = true;
      });
      _controller.play();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF0A1128),
      contentPadding: EdgeInsets.zero,
      content: _initialized
          ? AspectRatio(
              aspectRatio: _controller.value.aspectRatio,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  VideoPlayer(_controller),
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        _controller.value.isPlaying ? _controller.pause() : _controller.play();
                      });
                    },
                    child: Container(
                      color: Colors.transparent,
                      child: Icon(
                        _controller.value.isPlaying ? Icons.pause_circle_outline : Icons.play_circle_outline,
                        size: 60,
                        color: Colors.white70,
                      ),
                    ),
                  ),
                ],
              ),
            )
          : const SizedBox(
              height: 150,
              child: Center(child: CircularProgressIndicator(color: Color(0xFF00B4D8))),
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('إغلاق', style: TextStyle(color: Colors.white70)),
        ),
      ],
    );
  }
}