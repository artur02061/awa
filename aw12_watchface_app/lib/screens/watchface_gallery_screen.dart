import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../services/ble_service.dart';

class WatchFaceGalleryScreen extends StatefulWidget {
  const WatchFaceGalleryScreen({Key? key}) : super(key: key);

  @override
  State<WatchFaceGalleryScreen> createState() => _WatchFaceGalleryScreenState();
}

class _WatchFaceGalleryScreenState extends State<WatchFaceGalleryScreen> {
  final BleService _bleService = BleService();
  final ImagePicker _picker = ImagePicker();

  int _currentWatchFace = 1;
  int _uploadProgress = -1;
  bool _isUploading = false;
  bool _isSwitching = false;
  String? _previewImagePath;
  final List<StreamSubscription> _subs = [];

  final List<WatchFaceOption> _builtInFaces = [
    WatchFaceOption(index: 1, name: 'Классический', icon: Icons.access_time, color: Colors.blue),
    WatchFaceOption(index: 2, name: 'Спортивный', icon: Icons.fitness_center, color: Colors.orange),
    WatchFaceOption(index: 3, name: 'Цифровой', icon: Icons.grid_view, color: Colors.purple),
    WatchFaceOption(index: 4, name: 'Кастомный', icon: Icons.brush, color: Colors.tealAccent),
  ];

  @override
  void initState() {
    super.initState();
    _loadCurrentWatchFace();

    _subs.add(_bleService.watchFaceProgress.listen((progress) {
      if (!mounted) return;
      setState(() {
        _uploadProgress = progress;
        if (progress >= 100 || progress < 0) {
          _isUploading = false;
          _previewImagePath = null;
          if (progress >= 100) {
            _showSnackBar('Циферблат успешно загружен!', Colors.green);
          } else {
            _showSnackBar('Ошибка загрузки', Colors.red);
          }
        }
      });
    }));

    _subs.add(_bleService.errors.listen((error) {
      if (!mounted) return;
      setState(() => _isUploading = false);
      _showSnackBar(error, Colors.red);
    }));

    _subs.add(_bleService.connectionState.listen((connected) {
      if (!mounted) return;
      if (!connected) {
        setState(() => _isUploading = false);
        _showSnackBar('Часы отключились', Colors.red);
        Navigator.of(context).pop();
      }
    }));
  }

  Future<void> _loadCurrentWatchFace() async {
    try {
      final face = await _bleService.getDisplayWatchFace();
      if (mounted) setState(() => _currentWatchFace = face);
    } catch (e) {
      print('Error loading watch face: $e');
    }
  }

  Future<void> _setBuiltInWatchFace(int index) async {
    if (_isSwitching || _isUploading) return;
    setState(() => _isSwitching = true);
    try {
      await _bleService.setDisplayWatchFace(index);
      setState(() => _currentWatchFace = index);
      _showSnackBar('Циферблат переключён!', Colors.tealAccent);
    } catch (e) {
      _showSnackBar('Ошибка: $e', Colors.red);
    } finally {
      if (mounted) setState(() => _isSwitching = false);
    }
  }

  // ──────── Image picking ────────

  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? image = await _picker.pickImage(
        source: source,
        maxWidth: 480,
        maxHeight: 480,
        imageQuality: 95,
      );
      if (image == null) return;
      setState(() => _previewImagePath = image.path);
    } catch (e) {
      _showSnackBar('Ошибка выбора: $e', Colors.red);
    }
  }

  Future<void> _confirmAndUploadImage() async {
    if (_previewImagePath == null || _isUploading) return;
    setState(() {
      _isUploading = true;
      _uploadProgress = 0;
    });
    try {
      await _bleService.sendWatchFaceBackground(_previewImagePath!);
    } catch (e) {
      setState(() {
        _isUploading = false;
        _previewImagePath = null;
      });
      _showSnackBar('Ошибка: $e', Colors.red);
    }
  }

  void _cancelPreview() {
    setState(() => _previewImagePath = null);
  }

  // ──────── .bin file picking ────────

  Future<void> _pickBinFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      if (file.path == null) return;

      final ext = file.name.split('.').last.toLowerCase();
      if (ext != 'bin') {
        _showSnackBar('Выберите файл .bin', Colors.orange);
        return;
      }

      setState(() {
        _isUploading = true;
        _uploadProgress = 0;
      });

      await _bleService.sendWatchFace(file.path!);
    } catch (e) {
      setState(() => _isUploading = false);
      _showSnackBar('Ошибка: $e', Colors.red);
    }
  }

  void _showSnackBar(String message, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color.withValues(alpha: 0.9),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  @override
  void dispose() {
    for (var sub in _subs) {
      sub.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isUploading,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _isUploading) {
          _showSnackBar('Дождитесь окончания загрузки', Colors.orange);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Циферблаты'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _isUploading ? null : () => Navigator.pop(context),
          ),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Upload progress
              if (_isUploading) _buildUploadProgress(),

              // Preview
              if (_previewImagePath != null && !_isUploading) _buildPreview(),

              // Custom image section
              _buildSectionTitle('Свой циферблат'),
              const SizedBox(height: 12),
              _buildCustomImageSection(),
              const SizedBox(height: 28),

              // .bin upload
              _buildSectionTitle('Загрузить файл .bin'),
              const SizedBox(height: 12),
              _buildBinUploadSection(),
              const SizedBox(height: 28),

              // Built-in faces
              _buildSectionTitle('Встроенные циферблаты'),
              const SizedBox(height: 12),
              _buildBuiltInFaces(),
              const SizedBox(height: 28),

              _buildInfoCard(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.bold,
        color: Colors.white,
      ),
    );
  }

  Widget _buildUploadProgress() {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A3E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.tealAccent.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _uploadProgress >= 0
                      ? 'Загрузка: $_uploadProgress%'
                      : 'Подготовка...',
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _uploadProgress >= 0 ? _uploadProgress / 100 : null,
              backgroundColor: Colors.white12,
              valueColor: const AlwaysStoppedAnimation(Colors.tealAccent),
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Не выключайте Bluetooth и держите часы рядом',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildPreview() {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A3E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.tealAccent.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          const Text(
            'Предпросмотр',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(120),
            child: Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.tealAccent.withValues(alpha: 0.3), width: 2),
              ),
              child: ClipOval(
                child: Image.file(
                  File(_previewImagePath!),
                  width: 200,
                  height: 200,
                  fit: BoxFit.cover,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Так примерно будет выглядеть\nна круглом экране часов',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 12),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _cancelPreview,
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.white24),
                    foregroundColor: Colors.white70,
                  ),
                  child: const Text('Отмена'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _confirmAndUploadImage,
                  icon: const Icon(Icons.upload, size: 18),
                  label: const Text('Загрузить'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCustomImageSection() {
    final disabled = _isUploading || _previewImagePath != null;
    return Row(
      children: [
        Expanded(
          child: _buildActionCard(
            icon: Icons.photo_library,
            title: 'Из галереи',
            subtitle: 'Выбрать фото',
            onTap: disabled ? null : () => _pickImage(ImageSource.gallery),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildActionCard(
            icon: Icons.camera_alt,
            title: 'Камера',
            subtitle: 'Сделать фото',
            onTap: disabled ? null : () => _pickImage(ImageSource.camera),
          ),
        ),
      ],
    );
  }

  Widget _buildBinUploadSection() {
    return _buildActionCard(
      icon: Icons.file_upload_outlined,
      title: 'Загрузить .bin файл',
      subtitle: 'Выберите файл циферблата',
      onTap: (_isUploading || _previewImagePath != null) ? null : _pickBinFile,
    );
  }

  Widget _buildActionCard({
    required IconData icon,
    required String title,
    required String subtitle,
    VoidCallback? onTap,
  }) {
    final disabled = onTap == null;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedOpacity(
        opacity: disabled ? 0.5 : 1.0,
        duration: const Duration(milliseconds: 200),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.tealAccent.withValues(alpha: 0.15),
                Colors.tealAccent.withValues(alpha: 0.05),
              ],
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.tealAccent.withValues(alpha: 0.3)),
          ),
          child: Column(
            children: [
              Icon(icon, size: 40, color: Colors.tealAccent),
              const SizedBox(height: 10),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 12,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBuiltInFaces() {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 1.1,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: _builtInFaces.length,
      itemBuilder: (context, index) {
        final face = _builtInFaces[index];
        final isActive = _currentWatchFace == face.index;

        return GestureDetector(
          onTap: (_isUploading || _isSwitching)
              ? null
              : () => _setBuiltInWatchFace(face.index),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: isActive
                  ? face.color.withValues(alpha: 0.2)
                  : const Color(0xFF2A2A3E),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isActive ? face.color : Colors.transparent,
                width: isActive ? 2 : 1,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: face.color.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: _isSwitching && !isActive
                      ? SizedBox(
                          width: 32,
                          height: 32,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: face.color,
                          ),
                        )
                      : Icon(face.icon, size: 32, color: face.color),
                ),
                const SizedBox(height: 10),
                Text(
                  face.name,
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                    fontSize: 14,
                  ),
                ),
                if (isActive)
                  Container(
                    margin: const EdgeInsets.only(top: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: face.color.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'Активен',
                      style: TextStyle(color: face.color, fontSize: 10),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildInfoCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, color: Colors.white.withValues(alpha: 0.5), size: 18),
              const SizedBox(width: 8),
              Text(
                'Подсказка',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Фото: используйте квадратные изображения 240×240 px. '
            'Круглая обрезка выполняется часами автоматически.\n\n'
            '.bin файлы: можно скачать с сайтов циферблатов для Da Fit / MoYoung часов. '
            'Во время загрузки часы перезагрузятся.',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.4),
              fontSize: 13,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class WatchFaceOption {
  final int index;
  final String name;
  final IconData icon;
  final Color color;

  WatchFaceOption({
    required this.index,
    required this.name,
    required this.icon,
    required this.color,
  });
}
