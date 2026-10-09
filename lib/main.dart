import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_video/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_video/return_code.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // تهيئة خدمة الخلفية قبل تشغيل التطبيق
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

  // تهيئة إعدادات الإشعار والخدمة في الخلفية متوافقة مع أندرويد 15
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

  // جلب المجلدات المحفوظة من الذاكرة
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

  // دلالة تقسيم الفيديو المتوافقة مع الخلفية
  Future<void> _startSplitting(int seconds) async {
    final XFile? video = await _picker.pickVideo(source: ImageSource.gallery);
    if (video == null) return;

    setState(() {
      _isProcessing = true;
      _status = 'جاري بدء التجزئة في الخلفية بأمان…';
    });

    // إطلاق الإشعار العلوي والخدمة الأمامية
    await FlutterForegroundTask.startService(
      notificationTitle: 'جاري تجزئة الفيديو الآن',
      notificationText: 'يرجى الانتظار، المعالجة مستمرة في الخلفية...',
    );

    try {
      final appDir = await getApplicationDocumentsDirectory();
      // استخراج اسم الفيديو الأصلي بدون الامتداد لتسمية المجلد به
      final originalName = video.name.split('.').first;
      final folderName = '${originalName}_${DateTime.now().millisecondsSinceEpoch}';
      final outputFolder = Directory('${appDir.path}/SplitVideos/$folderName');
      await outputFolder.create(recursive: true);

      final outputPathPattern = "${outputFolder.path}/part_%03d.mp4";
      
      // أمر التقسيم فائق السرعة عبر نسخ الترميز المباشر لقضم المقطع بثانية واحدة
      final ffmpegCommand = "-i ${video.path} -c copy -map 0 -f segment -segment_time $seconds -reset_timestamps 1 $outputPathPattern";

      await FFmpegKit.executeAsync(ffmpegCommand, (session) async {
        final returnCode = await session.getReturnCode();
        
        // إغلاق خدمة الخلفية فور انتهاء المعالجة
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

  // فتح صندوق المجلد لمشاهدة ومشاركة المقاطع الناتجة
  void _showFolderContents(Directory folder) {
    final files = folder.listSync().whereType<File>().toList();
    // ترتيب الملفات تصاعدياً حسب الاسم ليظهر part_000 ثم part_001
    files.sort((a, b) => a.path.compareTo(b.path));
    
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0A1128),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) {
            return Scaffold(
              backgroundColor: Colors.transparent,
              appBar: AppBar(
                title: Text('المقاطع المقسمة (${files.length})'),
                backgroundColor: Colors.transparent,
                elevation: 0,
                automaticallyImplyLeading: false,
              ),
              body: ListView.builder(
                controller: scrollController,
                itemCount: files.length,
                itemBuilder: (context, index) {
                  final file = files[index];
                  final name = file.path.split('/').last;
                  return ListTile(
                    leading: const Icon(Icons.video_file, color: Color(0xFF00B4D8)),
                    title: Text(name, style: const TextStyle(fontSize: 14)),
                    trailing: IconButton(
                      icon: const Icon(Icons.share, color: Colors.white70),
                      onPressed: () => Share.shareXFiles([XFile(file.path)]),
                    ),
                  );
                },
              ),
            );
          },
        );
      },
    );
  }

  // واجهة إدخال رقم ثواني مخصص من قبل المستخدم
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
            // صف الأزرار الجاهزة
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildTimeButton('15 ثانية', () => _startSplitting(15)),
                _buildTimeButton('30 ثانية', () => _startSplitting(30)),
                _buildTimeButton('60 ثانية', () => _startSplitting(60)),
              ],
            ),
            const SizedBox(height: 12),
            // زر الوقت المخصص بتصميم عريض ومميز
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
