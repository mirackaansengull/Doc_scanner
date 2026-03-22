import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:opencv_4/factory/pathfrom.dart';
import 'package:opencv_4/opencv_4.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const MyHomePage(title: 'opencv_4 Demo'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, this.title});

  final String? title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  Uint8List? _byte;
  String _versionOpenCV = 'OpenCV';
  bool _visible = false;
  final ImagePicker _picker = ImagePicker();

  static final ButtonStyle _tealButtonStyle = TextButton.styleFrom(
    foregroundColor: Colors.white,
    backgroundColor: Colors.teal,
    disabledForegroundColor: Colors.grey,
  );

  @override
  void initState() {
    super.initState();
    _getOpenCVVersion();
  }

  Future<void> testOpenCV({
    required String pathString,
    required CVPathFrom pathFrom,
    required double thresholdValue,
    required double maxThresholdValue,
    required int thresholdType,
  }) async {
    try {
      final dynamic raw = await Cv2.threshold(
        pathFrom: pathFrom,
        pathString: pathString,
        maxThresholdValue: maxThresholdValue,
        thresholdType: thresholdType,
        thresholdValue: thresholdValue,
      );
      if (!mounted) return;
      setState(() {
        _byte = raw is Uint8List ? raw : null;
        _visible = false;
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      debugPrint(e.message);
    }
  }

  Future<void> _getOpenCVVersion() async {
    final String? versionOpenCV = await Cv2.version();
    if (!mounted) return;
    setState(() {
      _versionOpenCV = 'OpenCV: ${versionOpenCV ?? '?'}';
    });
  }

  Future<void> _testFromAssets() async {
    setState(() => _visible = true);
    await testOpenCV(
      pathFrom: CVPathFrom.ASSETS,
      pathString: 'assets/Test.JPG',
      thresholdValue: 150,
      maxThresholdValue: 200,
      thresholdType: Cv2.THRESH_BINARY,
    );
  }

  Future<void> _testFromUrl() async {
    setState(() => _visible = true);
    await testOpenCV(
      pathFrom: CVPathFrom.URL,
      pathString:
          'https://mir-s3-cdn-cf.behance.net/project_modules/max_1200/16fe9f114930481.6044f05fca574.jpeg',
      thresholdValue: 150,
      maxThresholdValue: 200,
      thresholdType: Cv2.THRESH_BINARY,
    );
  }

  Future<void> _testFromCamera() async {
    final XFile? pickedFile = await _picker.pickImage(source: ImageSource.camera);
    if (pickedFile == null) return;
    if (!mounted) return;
    setState(() => _visible = true);
    await testOpenCV(
      pathFrom: CVPathFrom.GALLERY_CAMERA,
      pathString: pickedFile.path,
      thresholdValue: 150,
      maxThresholdValue: 200,
      thresholdType: Cv2.THRESH_BINARY,
    );
  }

  Future<void> _testFromGallery() async {
    final XFile? pickedFile = await _picker.pickImage(source: ImageSource.gallery);
    if (pickedFile == null) return;
    if (!mounted) return;
    setState(() => _visible = true);
    await testOpenCV(
      pathFrom: CVPathFrom.GALLERY_CAMERA,
      pathString: pickedFile.path,
      thresholdValue: 150,
      maxThresholdValue: 200,
      thresholdType: Cv2.THRESH_BINARY,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title ?? 'opencv_4'),
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 20),
              child: Center(
                child: Column(
                  children: <Widget>[
                    Text(
                      _versionOpenCV,
                      style: const TextStyle(fontSize: 23),
                    ),
                    Container(
                      margin: const EdgeInsets.only(top: 5),
                      child: _byte != null
                          ? Image.memory(
                              _byte!,
                              width: 300,
                              height: 300,
                              fit: BoxFit.fill,
                            )
                          : SizedBox(
                              width: 300,
                              height: 300,
                              child: Icon(
                                Icons.camera_alt,
                                color: Colors.grey[800],
                              ),
                            ),
                    ),
                    Visibility(
                      maintainAnimation: true,
                      maintainState: true,
                      visible: _visible,
                      child: const CircularProgressIndicator(),
                    ),
                    SizedBox(
                      width: MediaQuery.sizeOf(context).width - 40,
                      child: TextButton(
                        onPressed: _testFromAssets,
                        style: _tealButtonStyle,
                        child: const Text('test assets'),
                      ),
                    ),
                    SizedBox(
                      width: MediaQuery.sizeOf(context).width - 40,
                      child: TextButton(
                        onPressed: _testFromUrl,
                        style: _tealButtonStyle,
                        child: const Text('test url'),
                      ),
                    ),
                    SizedBox(
                      width: MediaQuery.sizeOf(context).width - 40,
                      child: TextButton(
                        onPressed: _testFromGallery,
                        style: _tealButtonStyle,
                        child: const Text('test gallery'),
                      ),
                    ),
                    SizedBox(
                      width: MediaQuery.sizeOf(context).width - 40,
                      child: TextButton(
                        onPressed: _testFromCamera,
                        style: _tealButtonStyle,
                        child: const Text('test camara'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
