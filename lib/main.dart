import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

List<CameraDescription> cameras = [];

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint('Error al obtener las cámaras: $e');
  }

  await Supabase.initialize(
    url: 'https://lncjvaoatrocyjwjapg.supabase.co',
    publishableKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxuY2p2YW9hdHJvY3lqd2phcGciLCJyb2xlIjoiYW5vbiIsImlhdCI6MTcyOTQ0NDk1MCwiZXhwIjoyMDQ1MDIwOTUwfQ.WAarV_D-Y5clbdLW941D4J_zV43UUecKIm5BsGtfsDM',
  );

  runApp(const AsastixApp());
}

class AsastixApp extends StatelessWidget {
  const AsastixApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Asastix Tótem Biométrico',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        textTheme: GoogleFonts.plusJakartaSansTextTheme(
          ThemeData.dark().textTheme,
        ),
      ),
      initialRoute: '/',
      routes: {
        '/': (context) => const TotemHomePage(),
        '/admin': (context) => const AdminEnrolamientoScreen(),
      },
    );
  }
}

// ==========================================
// MOTOR DE EXTRACCIÓN BIOMÉTRICA (GEOMETRÍA FACIAL)
// ==========================================
class BiometricEngine {
  static List<double>? extraerVectorBiometrico(Face face) {
    try {
      final leftEye = face.landmarks[FaceLandmarkType.leftEye]?.position;
      final rightEye = face.landmarks[FaceLandmarkType.rightEye]?.position;
      final noseBase = face.landmarks[FaceLandmarkType.noseBase]?.position;
      final mouthBottom = face.landmarks[FaceLandmarkType.bottomMouth]?.position;
      final leftEar = face.landmarks[FaceLandmarkType.leftEar]?.position;
      final rightEar = face.landmarks[FaceLandmarkType.rightEar]?.position;

      if (leftEye == null || rightEye == null || noseBase == null || mouthBottom == null) {
        return null;
      }

      double distEyes = sqrt(pow(rightEye.x - leftEye.x, 2) + pow(rightEye.y - leftEye.y, 2));
      if (distEyes == 0) {
        return null;
      }

      double eyeToNose = sqrt(pow(noseBase.x - ((leftEye.x + rightEye.x) / 2), 2) + pow(noseBase.y - ((leftEye.y + rightEye.y) / 2), 2)) / distEyes;
      double noseToMouth = sqrt(pow(mouthBottom.x - noseBase.x, 2) + pow(mouthBottom.y - noseBase.y, 2)) / distEyes;
      
      double leftEyeToNose = sqrt(pow(noseBase.x - leftEye.x, 2) + pow(noseBase.y - leftEye.y, 2)) / distEyes;
      double rightEyeToNose = sqrt(pow(noseBase.x - rightEye.x, 2) + pow(noseBase.y - rightEye.y, 2)) / distEyes;

      double earWidth = 0.0;
      if (leftEar != null && rightEar != null) {
        earWidth = sqrt(pow(rightEar.x - leftEar.x, 2) + pow(rightEar.y - leftEar.y, 2)) / distEyes;
      }

      return [
        eyeToNose,
        noseToMouth,
        leftEyeToNose,
        rightEyeToNose,
        earWidth,
        face.headEulerAngleX ?? 0.0,
        face.headEulerAngleY ?? 0.0,
        face.headEulerAngleZ ?? 0.0,
      ];
    } catch (e) {
      debugPrint('Error extrayendo vector biométrico: $e');
      return null;
    }
  }

  static double calcularDistancia(List<double> v1, List<double> v2) {
    if (v1.length != v2.length) {
      return 999.0;
    }
    double suma = 0.0;
    for (int i = 0; i < v1.length; i++) {
      suma += pow(v1[i] - v2[i], 2);
    }
    return sqrt(suma);
  }
}

// ==========================================
// PANTALLA PRINCIPAL DEL TÓTEM (BIOMÉTRICO)
// ==========================================
class TotemHomePage extends StatefulWidget {
  const TotemHomePage({super.key});

  @override
  State<TotemHomePage> createState() => _TotemHomePageState();
}

class _TotemHomePageState extends State<TotemHomePage> with SingleTickerProviderStateMixin {
  CameraController? _cameraController;
  bool _isCameraInitialized = false;
  bool _isProcessing = false;
  
  late final FaceDetector _faceDetector;
  bool _isDetectingFaces = false;

  String _estadoTotem = 'Esperando presencia...';
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.accurate,
        enableLandmarks: true,
        enableClassification: true,
      ),
    );

    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    if (cameras.isEmpty) {
      return;
    }

    // Seleccionar específicamente la cámara frontal
    final frontCamera = cameras.firstWhere(
      (camera) => camera.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    _cameraController = CameraController(
      frontCamera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
    );

    try {
      await _cameraController!.initialize();
      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
        });
        _iniciarEscaneoPasivoMLKit();
      }
    } catch (e) {
      debugPrint('Error al inicializar cámara: $e');
    }
  }

  void _iniciarEscaneoPasivoMLKit() {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }

    _cameraController!.startImageStream((CameraImage image) async {
      if (_isProcessing || _isDetectingFaces) {
        return;
      }
      _isDetectingFaces = true;

      try {
        final inputImage = _convertCameraImageToInputImage(image);
        if (inputImage != null) {
          final faces = await _faceDetector.processImage(inputImage);

          if (faces.isNotEmpty && !_isProcessing) {
            debugPrint('¡Rostro detectado en tiempo real! Ejecutando match biométrico...');
            await _cameraController?.stopImageStream();
            await _procesarReconocimientoBiometrico(faces.first);
          }
        }
      } catch (e) {
        debugPrint('Error en stream: $e');
      } finally {
        _isDetectingFaces = false;
      }
    });
  }

  InputImage? _convertCameraImageToInputImage(CameraImage image) {
    final frontCamera = cameras.firstWhere(
      (camera) => camera.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );
    final sensorOrientation = frontCamera.sensorOrientation;
    
    InputImageRotation? rotation;
    if (sensorOrientation == 90) {
      rotation = InputImageRotation.rotation90deg;
    } else if (sensorOrientation == 180) {
      rotation = InputImageRotation.rotation180deg;
    } else if (sensorOrientation == 270) {
      rotation = InputImageRotation.rotation270deg;
    } else {
      rotation = InputImageRotation.rotation0deg;
    }

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null;

    // Concatenar los planos en un solo Uint8List para NV21 / YUV420
    final WriteBuffer allBytes = WriteBuffer();
    for (final Plane plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();

    return InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: image.planes.first.bytesPerRow,
      ),
    );
  }

  Future<void> _procesarReconocimientoBiometrico(Face detectedFace) async {
    setState(() {
      _isProcessing = true;
      _estadoTotem = 'Comparando biometría...';
    });

    bool isValid = false;
    String nombreEmpleado = '';
    String cedulaEncontrada = '';

    try {
      final vectorActual = BiometricEngine.extraerVectorBiometrico(detectedFace);
      if (vectorActual != null) {
        final response = await Supabase.instance.client
            .from('empleados')
            .select('cedula, nombre, apellido, vector_embedding');

        if (response.isNotEmpty) {
          double menorDistancia = 999.0;
          Map<String, dynamic>? empleadoMatch;

          for (var emp in response) {
            final dynamic vectorData = emp['vector_embedding'];
            if (vectorData != null) {
              final String vectorStr = vectorData.toString();
              List<dynamic> parsedList = jsonDecode(vectorStr);
              List<double> vectorGuardado = parsedList.map((e) => (e as num).toDouble()).toList();

              double distancia = BiometricEngine.calcularDistancia(vectorActual, vectorGuardado);
              debugPrint('Distancia con ${emp['nombre']}: $distancia');

              if (distancia < menorDistancia && distancia < 0.25) {
                menorDistancia = distancia;
                empleadoMatch = emp;
              }
            }
          }

          if (empleadoMatch != null) {
            isValid = true;
            cedulaEncontrada = empleadoMatch['cedula'];
            nombreEmpleado = '${empleadoMatch['nombre']} ${empleadoMatch['apellido']}';

            await Supabase.instance.client.from('asistencias').insert({
              'cedula': cedulaEncontrada,
              'fecha_hora': DateTime.now().toIso8601String(),
            });
          }
        }
      }
    } catch (e) {
      debugPrint('Error en motor biométrico: $e');
    }

    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        Timer(const Duration(seconds: 3), () {
          if (Navigator.canPop(context)) {
            Navigator.pop(context);
          }
        });

        return AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isValid ? Icons.verified_user_rounded : Icons.gpp_bad_rounded,
                color: isValid ? const Color(0xFF22C55E) : const Color(0xFFEF4444),
                size: 72,
              ),
              const SizedBox(height: 16),
              Text(
                isValid ? '¡Acceso Concedido!' : 'Rostro No Reconocido',
                style: GoogleFonts.plusJakartaSans(
                  color: isValid ? const Color(0xFF22C55E) : const Color(0xFFEF4444),
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                isValid ? 'Bienvenido, $nombreEmpleado\nCédula: $cedulaEncontrada' : 'No se encontró coincidencia biométrica válida',
                textAlign: TextAlign.center,
                style: GoogleFonts.plusJakartaSans(color: Colors.white, fontSize: 16),
              ),
            ],
          ),
        );
      },
    );

    await Future.delayed(const Duration(seconds: 4));

    if (mounted) {
      setState(() {
        _isProcessing = false;
        _estadoTotem = 'Esperando presencia...';
      });
      _iniciarEscaneoPasivoMLKit();
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _faceDetector.close();
    _cameraController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final timeString = '${now.hour > 12 ? now.hour - 12 : (now.hour == 0 ? 12 : now.hour)}:${now.minute.toString().padLeft(2, '0')} ${now.hour >= 12 ? 'PM' : 'AM'}';

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  GestureDetector(
                    onLongPress: () => Navigator.pushNamed(context, '/admin'),
                    child: Text('ASASTIX', style: GoogleFonts.plusJakartaSans(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold, letterSpacing: 2.0)),
                  ),
                  Text(timeString, style: GoogleFonts.plusJakartaSans(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 90),
                ],
              ),
              const Spacer(),
              Container(
                width: MediaQuery.of(context).size.width * 0.75,
                height: MediaQuery.of(context).size.height * 0.55,
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: _isProcessing ? const Color(0xFF22C55E) : Colors.blueAccent, width: 2.5),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      _isCameraInitialized && _cameraController != null
                          ? AspectRatio(
                              aspectRatio: _cameraController!.value.aspectRatio,
                              child: CameraPreview(_cameraController!),
                            )
                          : const Center(child: CircularProgressIndicator(color: Colors.blueAccent)),
                      Positioned(
                        bottom: 16,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                          decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(20)),
                          child: Text(_estadoTotem, style: GoogleFonts.plusJakartaSans(color: Colors.white, fontWeight: FontWeight.w600)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              Text('Motor Biométrico Geométrico Activo', style: GoogleFonts.plusJakartaSans(color: Colors.white38, fontSize: 14)),
            ],
          ),
        ),
      ),
    );
  }
}

// ==========================================
// PANTALLA DE ENROLAMIENTO (ADMIN)
// ==========================================
class AdminEnrolamientoScreen extends StatefulWidget {
  const AdminEnrolamientoScreen({super.key});

  @override
  State<AdminEnrolamientoScreen> createState() => _AdminEnrolamientoScreenState();
}

class _AdminEnrolamientoScreenState extends State<AdminEnrolamientoScreen> {
  final TextEditingController _cedulaController = TextEditingController();
  final TextEditingController _nombreController = TextEditingController();
  final TextEditingController _apellidoController = TextEditingController();
  
  CameraController? _cameraController;
  bool _isCameraInitialized = false;
  bool _isSaving = false;
  bool _rostroDetectadoAdmin = false;
  List<double>? _vectorCapturadoAdmin;
  
  late final FaceDetector _adminFaceDetector;
  bool _isDetectingAdmin = false;

  @override
  void initState() {
    super.initState();
    _adminFaceDetector = FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.accurate,
        enableLandmarks: true,
        enableClassification: true,
      ),
    );
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    try {
      if (cameras.isNotEmpty) {
        final frontCamera = cameras.firstWhere(
          (camera) => camera.lensDirection == CameraLensDirection.front,
          orElse: () => cameras.first,
        );

        _cameraController = CameraController(
          frontCamera,
          ResolutionPreset.medium,
          enableAudio: false,
          imageFormatGroup: Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
        );

        await _cameraController!.initialize();
        if (mounted) {
          setState(() {
            _isCameraInitialized = true;
          });
          _iniciarVerificacionRostroAdmin();
        }
      }
    } catch (e) {
      debugPrint('Error cámara admin: $e');
    }
  }

  void _iniciarVerificacionRostroAdmin() {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;

    _cameraController!.startImageStream((CameraImage image) async {
      if (_isSaving || _isDetectingAdmin) return;
      _isDetectingAdmin = true;

      try {
        final inputImage = _convertCameraImageToInputImage(image);
        if (inputImage != null) {
          final faces = await _adminFaceDetector.processImage(inputImage);

          if (faces.isNotEmpty) {
            final vector = BiometricEngine.extraerVectorBiometrico(faces.first);
            if (vector != null && mounted) {
              setState(() {
                _rostroDetectadoAdmin = true;
                _vectorCapturadoAdmin = vector;
              });
            }
          } else {
            if (mounted && _rostroDetectadoAdmin) {
              setState(() {
                _rostroDetectadoAdmin = false;
              });
            }
          }
        }
      } catch (e) {
        debugPrint('Error en verificación admin stream: $e');
      } finally {
        _isDetectingAdmin = false;
      }
    });
  }

  InputImage? _convertCameraImageToInputImage(CameraImage image) {
    final frontCamera = cameras.firstWhere(
      (camera) => camera.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );
    final sensorOrientation = frontCamera.sensorOrientation;
    
    InputImageRotation? rotation;
    if (sensorOrientation == 90) {
      rotation = InputImageRotation.rotation90deg;
    } else if (sensorOrientation == 180) {
      rotation = InputImageRotation.rotation180deg;
    } else if (sensorOrientation == 270) {
      rotation = InputImageRotation.rotation270deg;
    } else {
      rotation = InputImageRotation.rotation0deg;
    }

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null;

    final WriteBuffer allBytes = WriteBuffer();
    for (final Plane plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();

    return InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: image.planes.first.bytesPerRow,
      ),
    );
  }

  @override
  void dispose() {
    _cameraController?.stopImageStream();
    _adminFaceDetector.close();
    _cameraController?.dispose();
    _cedulaController.dispose();
    _nombreController.dispose();
    _apellidoController.dispose();
    super.dispose();
  }

  Future<void> _capturarYRegistrarEmpleado() async {
    final cedula = _cedulaController.text.trim();
    final nombre = _nombreController.text.trim();
    final apellido = _apellidoController.text.trim();

    if (cedula.isEmpty || nombre.isEmpty || apellido.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Completa todos los campos')));
      return;
    }

    if (!_rostroDetectadoAdmin || _vectorCapturadoAdmin == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No se ha fijado una geometría facial clara')));
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      // Detenemos temporalmente el stream para tomar la foto limpia con takePicture
      await _cameraController?.stopImageStream();
      final XFile imageFile = await _cameraController!.takePicture();
      final bytes = await imageFile.readAsBytes();

      final String fileName = '$cedula.jpg';
      await Supabase.instance.client.storage
          .from('empleados_fotos')
          .uploadBinary(fileName, bytes, fileOptions: const FileOptions(upsert: true));

      final String fotoUrl = Supabase.instance.client.storage
          .from('empleados_fotos')
          .getPublicUrl(fileName);

      await Supabase.instance.client.from('empleados').upsert({
        'cedula': cedula,
        'nombre': nombre,
        'apellido': apellido,
        'foto_url': fotoUrl,
        'vector_embedding': jsonEncode(_vectorCapturadoAdmin),
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('¡Enrolamiento biométrico completado!')));
      _cedulaController.clear();
      _nombreController.clear();
      _apellidoController.clear();
      
      // Reiniciamos el stream de detección
      _iniciarVerificacionRostroAdmin();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        title: Text('Panel Admin - Enrolamiento Biométrico', style: GoogleFonts.plusJakartaSans(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Row(
          children: [
            Expanded(
              flex: 1,
              child: Column(
                children: [
                  TextField(
                    controller: _cedulaController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Cédula',
                      filled: true,
                      fillColor: const Color(0xFF1E293B),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _nombreController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Nombre',
                      filled: true,
                      fillColor: const Color(0xFF1E293B),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _apellidoController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Apellido',
                      filled: true,
                      fillColor: const Color(0xFF1E293B),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _rostroDetectadoAdmin ? const Color(0xFF065F46) : const Color(0xFF7F1D1D),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      _rostroDetectadoAdmin ? 'Geometría facial capturada' : 'Buscando rostro...',
                      style: GoogleFonts.plusJakartaSans(color: Colors.white, fontWeight: FontWeight.w600),
                    ),
                  ),
                  const Spacer(),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      onPressed: (_isSaving || !_rostroDetectadoAdmin) ? null : _capturarYRegistrarEmpleado,
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2563EB)),
                      child: _isSaving
                          ? const CircularProgressIndicator(color: Colors.white)
                          : Text('Guardar Enrolamiento', style: GoogleFonts.plusJakartaSans(color: Colors.white, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 40),
            Expanded(
              flex: 1,
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: _rostroDetectadoAdmin ? const Color(0xFF22C55E) : Colors.blueAccent,
                    width: 2.5,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: _isCameraInitialized && _cameraController != null
                      ? AspectRatio(
                          aspectRatio: _cameraController!.value.aspectRatio,
                          child: CameraPreview(_cameraController!),
                        )
                      : const Center(child: CircularProgressIndicator()),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
