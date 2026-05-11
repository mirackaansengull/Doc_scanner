import 'dart:io';
import 'dart:isolate';
import 'dart:math' show max;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:image/image.dart' as img;
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'package:opencv_4/factory/pathfrom.dart';
import 'package:opencv_4/opencv_4.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

const int _kMaxProcessSide = 2048;
const double _kPostSaturation = 3.0;
const double _kPostContrast = 1.20;

typedef _ScanPrepared = ({String path, Uint8List bytes, String? tempDirPath});

/// Okuma / decode / gerekirse yeniden boyutlandırma — ana thread’i kilitlemesin diye isolate’ta.
Future<_ScanPrepared> _prepareScanWork(String normalizedPath) async {
  final Uint8List fileBytes = await File(normalizedPath).readAsBytes();
  final img.Image? decoded = img.decodeImage(fileBytes);
  if (decoded == null) {
    throw StateError('Görüntü okunamadı.');
  }
  final int w = decoded.width;
  final int h = decoded.height;
  final int maxSide = w > h ? w : h;
  if (maxSide <= _kMaxProcessSide) {
    return (path: normalizedPath, bytes: fileBytes, tempDirPath: null);
  }
  final double scale = _kMaxProcessSide / maxSide;
  final int nw = max(1, (w * scale).round());
  final int nh = max(1, (h * scale).round());
  final img.Image resized = img.copyResize(
    decoded,
    width: nw,
    height: nh,
    interpolation: img.Interpolation.linear,
  );
  final Uint8List jpegBytes = Uint8List.fromList(
    img.encodeJpg(resized, quality: 92),
  );
  final Directory tempDir = await Directory.systemTemp.createTemp(
    'doc_scan_prep_',
  );
  final String outPath = '${tempDir.path}${Platform.pathSeparator}in.jpg';
  await File(outPath).writeAsBytes(jpegBytes);
  return (path: outPath, bytes: jpegBytes, tempDirPath: tempDir.path);
}

/// Piksel döngüsü + JPEG encode — en ağır kısım; isolate’ta çalışır.
Uint8List _magicColorDivideIsolate(
  Uint8List originalFileBytes,
  Uint8List blurredJpegBytes,
) {
  final img.Image? orig = img.decodeImage(originalFileBytes);
  final img.Image? blr = img.decodeImage(blurredJpegBytes);
  if (orig == null || blr == null) return originalFileBytes;

  img.Image blur = blr;
  if (blur.width != orig.width || blur.height != orig.height) {
    blur = img.copyResize(blur, width: orig.width, height: orig.height);
  }

  final img.Image out = img.Image.from(orig);
  final bool hasAlpha = orig.numChannels >= 4;
  const double eps = 1.0;
  const double scale = 255.0;

  for (var y = 0; y < orig.height; y++) {
    for (var x = 0; x < orig.width; x++) {
      final o = orig.getPixel(x, y);
      final b = blur.getPixel(x, y);
      final double br = max(b.r.toDouble(), eps);
      final double bg = max(b.g.toDouble(), eps);
      final double bb = max(b.b.toDouble(), eps);
      final int rr = (o.r * scale / br).clamp(0.0, 255.0).round();
      final int gg = (o.g * scale / bg).clamp(0.0, 255.0).round();
      final int bl = (o.b * scale / bb).clamp(0.0, 255.0).round();
      final dst = out.getPixel(x, y);
      if (hasAlpha) {
        dst.set(img.ColorRgba8(rr, gg, bl, o.a.toInt().clamp(0, 255)));
      } else {
        dst.set(img.ColorRgb8(rr, gg, bl));
      }
    }
  }

  img.adjustColor(
    out,
    saturation: _kPostSaturation.clamp(1.0, 1.5),
    contrast: _kPostContrast.clamp(1.0, 2.0),
  );

  return Uint8List.fromList(img.encodeJpg(out, quality: 92));
}

Future<_ScanPrepared> _prepareScanOffMain(String normalizedPath) {
  if (kIsWeb) {
    return _prepareScanWork(normalizedPath);
  }
  return Isolate.run(() => _prepareScanWork(normalizedPath));
}

Future<Uint8List> _magicColorOffMain(Uint8List original, Uint8List blurred) {
  if (kIsWeb) {
    return SynchronousFuture(_magicColorDivideIsolate(original, blurred));
  }
  return Isolate.run(() => _magicColorDivideIsolate(original, blurred));
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DocScannerApp());
}

/// Root widget: Material 3 shell for the document scanner demo.
class DocScannerApp extends StatelessWidget {
  const DocScannerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Doc Scanner',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const DocScannerHomePage(),
    );
  }
}

class DocScannerHomePage extends StatefulWidget {
  const DocScannerHomePage({super.key});

  @override
  State<DocScannerHomePage> createState() => _DocScannerHomePageState();
}

class _DocScannerHomePageState extends State<DocScannerHomePage> {
  final ImagePicker _picker = ImagePicker();
  final ImageCropper _cropper = ImageCropper();

  /// Path from [image_picker] / [image_cropper] (local file).
  String? _sourcePath;

  /// Cached bytes for the OpenCV output (JPEG from native).
  Uint8List? _processedBytes;

  bool _processing = false;

  /// On narrow layouts we toggle which single image is shown.
  bool _showProcessedOnNarrow = false;

  /// Magic Color: hazırlık + OpenCV blur (ana isolate) + bölme/adjust (arka isolate).
  Future<Uint8List> _runScannerPipeline(String imagePath) async {
    final String normalizedPath = imagePath.replaceFirst('file://', '');
    final _ScanPrepared prep = await _prepareScanOffMain(normalizedPath);
    final Directory? tempDir = prep.tempDirPath != null
        ? Directory(prep.tempDirPath!)
        : null;
    try {
      final Uint8List? blurredBytes = await Cv2.gaussianBlur(
        pathFrom: CVPathFrom.GALLERY_CAMERA,
        pathString: prep.path,
        kernelSize: const [71, 71],
        sigmaX: 0,
      );
      if (blurredBytes == null || blurredBytes.isEmpty) {
        throw StateError('Gaussian blur returned no data.');
      }
      return _magicColorOffMain(prep.bytes, blurredBytes);
    } finally {
      try {
        await tempDir?.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Opens native crop UI; returns `null` if user cancels or on failure we keep the picked file.
  ///
  /// Android’da bazen uCrop `y + height must be <= bitmap.height()` (bitmap bölgesi taşması) fırlatır;
  /// bu durumda `null` dönülür, [_pickImage] seçilen orijinal dosyayla devam eder.
  Future<String?> _cropImagePath(String sourcePath) async {
    if (kIsWeb) {
      return sourcePath;
    }
    try {
      final CroppedFile? cropped = await _cropper.cropImage(
        sourcePath: sourcePath.replaceFirst('file://', ''),
        maxWidth: 8192,
        maxHeight: 8192,
        compressFormat: ImageCompressFormat.jpg,
        compressQuality: 92,
        uiSettings: [
          AndroidUiSettings(
            toolbarTitle: 'Belgeyi kırp',
            toolbarColor: const Color(0xFF00796B),
            toolbarWidgetColor: Colors.white,
            activeControlsWidgetColor: Colors.tealAccent,
            initAspectRatio: CropAspectRatioPreset.original,
            lockAspectRatio: false,
          ),
          IOSUiSettings(
            title: 'Belgeyi kırp',
            doneButtonTitle: 'Tamam',
            cancelButtonTitle: 'İptal',
            aspectRatioLockEnabled: false,
          ),
        ],
      );
      return cropped?.path;
    } on PlatformException catch (e, st) {
      debugPrint('image_cropper: ${e.message ?? e.code}\n$st');
      return null;
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? file = await _picker.pickImage(
        source: source,
        // Çok büyük bitmap’ler uCrop’ta sınır taşması hatalarına yol açabiliyor.
        maxWidth: 4096,
        maxHeight: 4096,
        imageQuality: 95,
      );
      if (!mounted) return;
      if (file == null) return;

      String path = file.path;
      if (!kIsWeb) {
        final String? croppedPath = await _cropImagePath(path);
        if (!mounted) return;
        if (croppedPath != null) {
          path = croppedPath;
        }
      }

      setState(() {
        _sourcePath = path;
        _processedBytes = null;
        _showProcessedOnNarrow = false;
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      _showError('Görüntü alınamadı: ${e.message ?? e.code}');
    } catch (e) {
      if (!mounted) return;
      _showError('Hata: $e');
    }
  }

  void _showAddImageSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Galeriden seç'),
              onTap: () {
                Navigator.pop(ctx);
                _pickImage(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Kamera ile çek'),
              onTap: () {
                Navigator.pop(ctx);
                _pickImage(ImageSource.camera);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _recropCurrentImage() async {
    final String? path = _sourcePath;
    if (path == null || kIsWeb) return;
    try {
      final String? croppedPath = await _cropImagePath(path);
      if (!mounted) return;
      if (croppedPath == null) return;
      setState(() {
        _sourcePath = croppedPath;
        _processedBytes = null;
      });
    } catch (e) {
      if (!mounted) return;
      _showError('Kırpma başarısız: $e');
    }
  }

  Future<void> _processImage() async {
    final String? path = _sourcePath;
    if (path == null) {
      _showError('Önce bir görüntü ekleyin.');
      return;
    }

    setState(() => _processing = true);
    try {
      final Uint8List result = await _runScannerPipeline(path);
      if (!mounted) return;
      setState(() {
        _processedBytes = result;
        _showProcessedOnNarrow = true;
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      _showError('OpenCV: ${e.message ?? e.code}');
    } catch (e) {
      if (!mounted) return;
      _showError('İşleme başarısız: $e');
    } finally {
      if (mounted) {
        setState(() => _processing = false);
      }
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _showInfo(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Sistem paylaşım sayfası (WhatsApp, E-posta vb.).
  Future<void> _shareProcessedImage() async {
    final Uint8List? bytes = _processedBytes;
    if (bytes == null || !mounted) return;
    try {
      final Directory dir = await getTemporaryDirectory();
      final File file = File(
        '${dir.path}${Platform.pathSeparator}belge_islenmis_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      await file.writeAsBytes(bytes);
      // Sadece dosya: `text` verilirse WhatsApp’ta görselin altında yazı olarak çıkar.
      await SharePlus.instance.share(
        ShareParams(
          files: <XFile>[
            XFile(
              file.path,
              mimeType: 'image/jpeg',
              name: 'belge_islenmis.jpg',
            ),
          ],
          title: 'Belgeyi paylaş',
        ),
      );
    } catch (e) {
      if (mounted) _showError('Paylaşılamadı: $e');
    }
  }

  /// Fotoğraflar / Galeri (mobil).
  Future<void> _saveProcessedToGallery() async {
    final Uint8List? bytes = _processedBytes;
    if (bytes == null || !mounted) return;
    if (kIsWeb) {
      _showInfo('Web’de dosyayı paylaş ile kaydedebilirsiniz.');
      return;
    }
    try {
      final bool allowed = await Gal.requestAccess();
      if (!allowed) {
        if (mounted) _showError('Galeriye kayıt için izin gerekli.');
        return;
      }
      await Gal.putImageBytes(bytes, name: 'belge_islenmis');
      if (mounted) {
        _showInfo('Fotoğraflar uygulamasına kaydedildi.');
      }
    } on GalException catch (e) {
      if (mounted) _showError('Kaydedilemedi: $e');
    } catch (e) {
      if (mounted) _showError('Kaydedilemedi: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool canExport = _processedBytes != null && !_processing;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Doc Scanner'),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: 'Kırp',
            onPressed: (_sourcePath == null || _processing || kIsWeb)
                ? null
                : _recropCurrentImage,
            icon: const Icon(Icons.crop),
          ),
        ],
      ),
      bottomNavigationBar: canExport
          ? SafeArea(
              child: Material(
                elevation: 6,
                color: Theme.of(context).colorScheme.surface,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _shareProcessedImage,
                          icon: const Icon(Icons.share_outlined),
                          label: const Text('Paylaş'),
                        ),
                      ),
                      if (!kIsWeb) ...[
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _saveProcessedToGallery,
                            icon: const Icon(Icons.save_alt_outlined),
                            label: const Text('Kaydet'),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            )
          : null,
      body: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final bool sideBySide = constraints.maxWidth >= 560;
                if (sideBySide) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: _ImagePanel(
                          label: 'Orijinal',
                          child: _buildOriginalPreview(),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _ImagePanel(
                          label: 'İşlenmiş',
                          child: _buildProcessedPreview(),
                        ),
                      ),
                    ],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment<bool>(
                          value: false,
                          label: Text('Orijinal'),
                          icon: Icon(Icons.image_outlined),
                        ),
                        ButtonSegment<bool>(
                          value: true,
                          label: Text('İşlenmiş'),
                          icon: Icon(Icons.document_scanner_outlined),
                        ),
                      ],
                      selected: {_showProcessedOnNarrow},
                      onSelectionChanged: (Set<bool> next) {
                        setState(() => _showProcessedOnNarrow = next.single);
                      },
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: _ImagePanel(
                        label: _showProcessedOnNarrow ? 'İşlenmiş' : 'Orijinal',
                        child: _showProcessedOnNarrow
                            ? _buildProcessedPreview()
                            : _buildOriginalPreview(),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          if (_processing)
            const ColoredBox(
              color: Color(0x66000000),
              child: Center(
                child: Card(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        Text('Belge iyileştiriliyor…'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.extended(
            heroTag: 'add',
            onPressed: _processing ? null : _showAddImageSheet,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: const Text('Resim ekle'),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'process',
            onPressed: _processing ? null : _processImage,
            icon: const Icon(Icons.auto_fix_high),
            label: const Text('İşle'),
          ),
        ],
      ),
    );
  }

  Widget _buildOriginalPreview() {
    final String? path = _sourcePath;
    if (path == null) {
      return const _EmptyHint(
        icon: Icons.add_photo_alternate_outlined,
        message:
            '“Resim ekle” ile galeriden seçin veya kamerayla çekin. Ardından kırpma ekranı açılır.',
      );
    }
    return Image.file(
      File(path),
      fit: BoxFit.contain,
      gaplessPlayback: true,
      errorBuilder: (context, error, stackTrace) => const _EmptyHint(
        icon: Icons.broken_image_outlined,
        message: 'Dosya gösterilemedi.',
      ),
    );
  }

  Widget _buildProcessedPreview() {
    final Uint8List? bytes = _processedBytes;
    if (bytes == null) {
      return const _EmptyHint(
        icon: Icons.document_scanner_outlined,
        message: '“İşle” ile tarayıcı efektini uygulayın.',
      );
    }
    return Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true);
  }
}

class _ImagePanel extends StatelessWidget {
  const _ImagePanel({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.titleSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: child,
          ),
        ),
      ],
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
