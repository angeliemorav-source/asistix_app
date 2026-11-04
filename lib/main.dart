import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;

List<CameraDescription> cameras = [];

/// Archivo del modelo (debe existir en assets/ y estar en el pubspec).
const String kModeloAsset = 'assets/mobilefacenet.tflite';

/// Normalización de entrada del modelo. MobileFaceNet típico: (px-127.5)/128.
/// Si tu modelo espera 0..1, usa media=0.0 y desviacion=255.0.
const double kNormMedia = 127.5;
const double kNormDesviacion = 128.0;

/// Cuántas capturas se promedian al enrolar a una persona.
const int kMuestrasEnrolamiento = 5;

/// Frames consecutivos con buena calidad antes de identificar en el tótem.
const int kFramesEstables = 3;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint('Error al obtener las cámaras: $e');
  }

  await FaceEmbedder.load();

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
// CameraImage -> InputImage (para ML Kit)
// ==========================================
class FaceInput {
  static const Map<DeviceOrientation, int> _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  static InputImage? fromCameraImage(CameraImage image, CameraController controller) {
    final cam = controller.description;
    final deviceRot = _orientations[controller.value.deviceOrientation];
    if (deviceRot == null) return null;

    final int comp = cam.lensDirection == CameraLensDirection.front
        ? (cam.sensorOrientation + deviceRot) % 360
        : (cam.sensorOrientation - deviceRot + 360) % 360;

    final rotation = InputImageRotationValue.fromRawValue(comp);
    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (rotation == null || format == null) return null;
    if (Platform.isAndroid && format != InputImageFormat.nv21) return null;

    Uint8List bytes;
    if (image.planes.length == 1) {
      bytes = image.planes.first.bytes;
    } else {
      final WriteBuffer allBytes = WriteBuffer();
      for (final Plane plane in image.planes) {
        allBytes.putUint8List(plane.bytes);
      }
      bytes = allBytes.done().buffer.asUint8List();
    }

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
}

// ==========================================
// CONTROL DE CALIDAD DEL ROSTRO
// ==========================================
class FaceQuality {
  /// Devuelve null si el rostro es apto, o un mensaje para el usuario.
  static String? evaluar(Face f, int anchoVertical) {
    if (f.boundingBox.width < anchoVertical * 0.28) {
      return 'Acércate un poco';
    }
    if ((f.headEulerAngleY ?? 0).abs() > 15 ||
        (f.headEulerAngleX ?? 0).abs() > 15 ||
        (f.headEulerAngleZ ?? 0).abs() > 15) {
      return 'Mira de frente a la cámara';
    }
    return null;
  }

  /// Ancho de la imagen ya girada "derecha".
  static int anchoVertical(CameraImage image, int rotacionGrados) {
    return (rotacionGrados == 90 || rotacionGrados == 270) ? image.height : image.width;
  }
}

// ==========================================
// MOTOR DE EMBEDDINGS (MobileFaceNet / TFLite)
// ==========================================
class FaceEmbedder {
  static Interpreter? _interpreter;
  static int inputW = 112;
  static int inputH = 112;
  static int outDim = 192;
  static String estado = 'Modelo sin cargar';
  static bool get listo => _interpreter != null;

  static Future<void> load() async {
    if (_interpreter != null) return;
    try {
      final options = InterpreterOptions()..threads = 2;
      final it = await Interpreter.fromAsset(kModeloAsset, options: options);

      final inShape = it.getInputTensor(0).shape; // esperado [1, h, w, 3]
      final outShape = it.getOutputTensor(0).shape; // esperado [1, dim]
      if (inShape.length != 4 || inShape[3] != 3) {
        throw 'Entrada inesperada del modelo: $inShape (se espera [1,h,w,3])';
      }
      inputH = inShape[1];
      inputW = inShape[2];
      outDim = outShape.last;
      _interpreter = it;
      estado = 'Modelo OK: entrada=${inputW}x$inputH salida=$outDim';
    } catch (e) {
      estado = 'No se pudo cargar el modelo: $e';
    }
    debugPrint(estado);
  }

  /// NV21 (un solo plano: Y seguido de VU intercalado) -> RGB.
  static img.Image _nv21ToImage(CameraImage image) {
    final w = image.width;
    final h = image.height;
    final bytes = image.planes[0].bytes;
    final out = img.Image(width: w, height: h);
    final uvStart = w * h;

    for (int y = 0; y < h; y++) {
      final yRow = y * w;
      final uvRow = uvStart + (y >> 1) * w;
      for (int x = 0; x < w; x++) {
        final yy = bytes[yRow + x];
        final uvIdx = uvRow + (x & ~1);
        final v = bytes[uvIdx] - 128;
        final u = bytes[uvIdx + 1] - 128;
        final r = (yy + 1.402 * v).round().clamp(0, 255).toInt();
        final g = (yy - 0.344136 * u - 0.714136 * v).round().clamp(0, 255).toInt();
        final b = (yy + 1.772 * u).round().clamp(0, 255).toInt();
        out.setPixelRgb(x, y, r, g, b);
      }
    }
    return out;
  }

  /// Calcula el embedding (L2-normalizado) del rostro dentro de [box]
  /// (coordenadas de la imagen ya girada, tal como las da ML Kit).
  static List<double>? embed(CameraImage image, int rotacionGrados, Rect box) {
    final it = _interpreter;
    if (it == null) return null;
    if (Platform.isAndroid && image.planes.length != 1) return null;

    try {
      var frame = _nv21ToImage(image);
      if (rotacionGrados != 0) {
        frame = img.copyRotate(frame, angle: rotacionGrados); // sentido horario
      }

      // Recorte cuadrado centrado en el rostro, con margen.
      final side = max(box.width, box.height) * 1.15;
      int x0 = (box.center.dx - side / 2).round().clamp(0, frame.width - 1).toInt();
      int y0 = (box.center.dy - side / 2).round().clamp(0, frame.height - 1).toInt();
      int s = min(side.round(), min(frame.width - x0, frame.height - y0));
      if (s < 40) return null;

      final crop = img.copyCrop(frame, x: x0, y: y0, width: s, height: s);
      final resized = img.copyResize(
        crop,
        width: inputW,
        height: inputH,
        interpolation: img.Interpolation.linear,
      );

      final input = [
        List.generate(inputH, (y) {
          return List.generate(inputW, (x) {
            final p = resized.getPixel(x, y);
            return [
              (p.r.toDouble() - kNormMedia) / kNormDesviacion,
              (p.g.toDouble() - kNormMedia) / kNormDesviacion,
              (p.b.toDouble() - kNormMedia) / kNormDesviacion,
            ];
          });
        })
      ];
      final output = [List<double>.filled(outDim, 0.0)];

      it.run(input, output);
      return _normalizar(List<double>.from(output[0]));
    } catch (e) {
      debugPrint('Error generando embedding: $e');
      return null;
    }
  }

  static List<double> _normalizar(List<double> v) {
    double suma = 0;
    for (final x in v) {
      suma += x * x;
    }
    final norma = sqrt(suma);
    if (norma == 0) return v;
    return v.map((x) => x / norma).toList();
  }

  /// Promedia varias muestras y vuelve a normalizar.
  static List<double> promediar(List<List<double>> muestras) {
    final n = muestras.first.length;
    final acc = List<double>.filled(n, 0.0);
    for (final m in muestras) {
      for (int i = 0; i < n; i++) {
        acc[i] += m[i];
      }
    }
    return _normalizar(acc.map((x) => x / muestras.length).toList());
  }
}

// ==========================================
// PANTALLA PRINCIPAL DEL TÓTEM
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
  int _estables = 0;

  String _estadoTotem = 'Esperando presencia...';
  String _debug = 'Iniciando...'; // quitar cuando todo funcione
  int _frames = 0;
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
        performanceMode: FaceDetectorMode.fast,
        enableLandmarks: false,
        enableClassification: false,
      ),
    );

    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    if (!FaceEmbedder.listo) {
      setState(() => _debug = FaceEmbedder.estado);
      return;
    }
    if (cameras.isEmpty) {
      setState(() => _debug = 'No se encontraron cámaras (¿permiso denegado?)');
      return;
    }

    final frontCamera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
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
          _debug = FaceEmbedder.estado;
        });
        _iniciarEscaneoPasivoMLKit();
      }
    } catch (e) {
      debugPrint('Error al inicializar cámara: $e');
      if (mounted) setState(() => _debug = 'Error cámara: $e');
    }
  }

  void _setEstado(String msg) {
    if (mounted && _estadoTotem != msg) {
      setState(() => _estadoTotem = msg);
    }
  }

  void _setDebug(String msg) {
    _debug = msg;
    if (mounted && _frames % 5 == 0) setState(() {});
  }

  void _iniciarEscaneoPasivoMLKit() {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isStreamingImages) return;

    controller.startImageStream((CameraImage image) async {
      if (_isProcessing || _isDetectingFaces) return;
      _isDetectingFaces = true;

      try {
        _frames++;
        final inputImage = FaceInput.fromCameraImage(image, controller);
        if (inputImage == null) {
          _setDebug('Imagen inválida: fmt=${image.format.raw} planos=${image.planes.length}');
          return;
        }

        final faces = await _faceDetector.processImage(inputImage);
        _setDebug('frames=$_frames rostros=${faces.length}');

        if (faces.isEmpty) {
          _estables = 0;
          _setEstado('Esperando presencia...');
          return;
        }

        final rot = inputImage.metadata!.rotation.rawValue;
        final face = faces.first;
        final problema = FaceQuality.evaluar(face, FaceQuality.anchoVertical(image, rot));
        if (problema != null) {
          _estables = 0;
          _setEstado(problema);
          return;
        }

        _estables++;
        if (_estables < kFramesEstables) {
          _setEstado('Mantén la posición...');
          return;
        }
        _estables = 0;

        _setEstado('Analizando rostro...');
        final embedding = FaceEmbedder.embed(image, rot, face.boundingBox);
        if (embedding == null) {
          _setEstado('No se pudo analizar, intenta de nuevo');
          return;
        }

        try {
          if (controller.value.isStreamingImages) {
            await controller.stopImageStream();
          }
        } catch (e) {
          debugPrint('Aviso al detener stream: $e');
        }

        await _identificar(embedding);
      } catch (e) {
        debugPrint('Error en stream: $e');
        _setDebug('Error en stream: $e');
      } finally {
        _isDetectingFaces = false;
      }
    });
  }

  Future<void> _identificar(List<double> embedding) async {
    setState(() {
      _isProcessing = true;
      _estadoTotem = 'Buscando coincidencia...';
    });

    bool isValid = false;
    bool yaRegistrado = false;
    String nombreEmpleado = '';
    String cedulaEncontrada = '';
    double? distancia;
    String? error;

    try {
      final res = await Supabase.instance.client
          .rpc('identificar_y_registrar', params: {'query_embedding': jsonEncode(embedding)})
          .timeout(const Duration(seconds: 12));

      final rows = res as List;
      if (rows.isNotEmpty) {
        final r = Map<String, dynamic>.from(rows.first as Map);
        distancia = (r['distancia'] as num?)?.toDouble();
        if (r['encontrado'] == true) {
          isValid = true;
          yaRegistrado = r['ya_registrado'] == true;
          cedulaEncontrada = r['cedula'].toString();
          nombreEmpleado = '${r['nombre']} ${r['apellido']}';
        }
      }
      debugPrint('Resultado: valido=$isValid dist=$distancia');
      _debug = 'Última distancia: ${distancia?.toStringAsFixed(3) ?? '-'}';
    } catch (e) {
      debugPrint('Error identificando: $e');
      error = e.toString();
    }

    if (!mounted) return;

    final Color color = error != null
        ? const Color(0xFFF59E0B)
        : (isValid
            ? (yaRegistrado ? Colors.lightBlueAccent : const Color(0xFF22C55E))
            : const Color(0xFFEF4444));
    final String titulo = error != null
        ? 'Error de conexión'
        : (isValid
            ? (yaRegistrado ? '¡Ya registrado!' : '¡Asistencia registrada!')
            : 'Rostro No Reconocido');
    final String mensaje = error != null
        ? 'No se pudo consultar el servidor.\n$error'
        : (isValid
            ? '$nombreEmpleado\nCédula: $cedulaEncontrada'
            : 'No se encontró coincidencia biométrica válida');

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                error != null
                    ? Icons.wifi_off_rounded
                    : (isValid ? Icons.verified_user_rounded : Icons.gpp_bad_rounded),
                color: color,
                size: 72,
              ),
              const SizedBox(height: 16),
              Text(
                titulo,
                textAlign: TextAlign.center,
                style: GoogleFonts.plusJakartaSans(color: color, fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                mensaje,
                textAlign: TextAlign.center,
                style: GoogleFonts.plusJakartaSans(color: Colors.white, fontSize: 16),
              ),
            ],
          ),
        );
      },
    );

    await Future.delayed(const Duration(seconds: 3));
    if (mounted && Navigator.canPop(context)) {
      Navigator.pop(context);
    }
    await Future.delayed(const Duration(seconds: 1));

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
    try {
      if (_cameraController != null && _cameraController!.value.isStreamingImages) {
        _cameraController!.stopImageStream();
      }
    } catch (_) {}
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
              // Línea de diagnóstico: bórrala cuando todo funcione.
              Text(_debug, textAlign: TextAlign.center, style: GoogleFonts.plusJakartaSans(color: Colors.amberAccent, fontSize: 12)),
              const SizedBox(height: 6),
              Text('Reconocimiento facial por embeddings', style: GoogleFonts.plusJakartaSans(color: Colors.white38, fontSize: 14)),
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
  final TextEditingController _pinController = TextEditingController();
  final TextEditingController _cedulaController = TextEditingController();
  final TextEditingController _nombreController = TextEditingController();
  final TextEditingController _apellidoController = TextEditingController();

  CameraController? _cameraController;
  bool _isCameraInitialized = false;
  bool _isSaving = false;
  bool _rostroDetectadoAdmin = false;
  String _mensajeRostro = 'Buscando rostro...';
  String _debug = 'Iniciando cámara...';
  int _frames = 0;

  // Captura de muestras
  bool _capturando = false;
  final List<List<double>> _muestras = [];
  Completer<List<double>>? _completer;

  late final FaceDetector _adminFaceDetector;
  bool _isDetectingAdmin = false;

  @override
  void initState() {
    super.initState();
    _adminFaceDetector = FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.fast,
        enableLandmarks: false,
        enableClassification: false,
      ),
    );
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    try {
      if (!FaceEmbedder.listo) {
        setState(() => _debug = FaceEmbedder.estado);
        return;
      }
      if (cameras.isEmpty) {
        setState(() => _debug = 'No se encontraron cámaras');
        return;
      }
      final frontCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
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
          _debug = FaceEmbedder.estado;
        });
        _iniciarVerificacionRostroAdmin();
      }
    } catch (e) {
      debugPrint('Error cámara admin: $e');
      if (mounted) setState(() => _debug = 'Error cámara: $e');
    }
  }

  void _iniciarVerificacionRostroAdmin() {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isStreamingImages) return;

    controller.startImageStream((CameraImage image) async {
      if (_isDetectingAdmin) return;
      if (_isSaving && !_capturando) return;
      _isDetectingAdmin = true;

      try {
        _frames++;
        final inputImage = FaceInput.fromCameraImage(image, controller);
        if (inputImage == null) {
          if (mounted && _frames % 5 == 0) {
            setState(() => _debug = 'Imagen inválida: fmt=${image.format.raw} planos=${image.planes.length}');
          }
          return;
        }

        final faces = await _adminFaceDetector.processImage(inputImage);
        if (faces.isEmpty) {
          if (mounted && (_rostroDetectadoAdmin || _mensajeRostro != 'Buscando rostro...')) {
            setState(() {
              _rostroDetectadoAdmin = false;
              _mensajeRostro = 'Buscando rostro...';
            });
          }
          return;
        }

        final rot = inputImage.metadata!.rotation.rawValue;
        final face = faces.first;
        final problema = FaceQuality.evaluar(face, FaceQuality.anchoVertical(image, rot));
        final ok = problema == null;

        if (mounted && (ok != _rostroDetectadoAdmin)) {
          setState(() {
            _rostroDetectadoAdmin = ok;
            _mensajeRostro = problema ?? 'Rostro listo para capturar';
          });
        }

        if (ok && _capturando) {
          final emb = FaceEmbedder.embed(image, rot, face.boundingBox);
          if (emb != null) {
            _muestras.add(emb);
            if (mounted) {
              setState(() => _debug = 'Capturando muestra ${_muestras.length}/$kMuestrasEnrolamiento');
            }
            if (_muestras.length >= kMuestrasEnrolamiento) {
              _capturando = false;
              _completer?.complete(FaceEmbedder.promediar(_muestras));
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

  @override
  void dispose() {
    try {
      if (_cameraController != null && _cameraController!.value.isStreamingImages) {
        _cameraController?.stopImageStream();
      }
    } catch (_) {}
    _adminFaceDetector.close();
    _cameraController?.dispose();
    _pinController.dispose();
    _cedulaController.dispose();
    _nombreController.dispose();
    _apellidoController.dispose();
    super.dispose();
  }

  Future<void> _capturarYRegistrarEmpleado() async {
    final pin = _pinController.text.trim();
    final cedula = _cedulaController.text.trim();
    final nombre = _nombreController.text.trim();
    final apellido = _apellidoController.text.trim();

    if (pin.isEmpty || cedula.isEmpty || nombre.isEmpty || apellido.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Completa todos los campos (incluido el PIN)')));
      return;
    }
    if (!_rostroDetectadoAdmin) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Coloca el rostro de frente y a buena distancia')));
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      // 1) Capturar varias muestras y promediar
      _muestras.clear();
      _completer = Completer<List<double>>();
      _capturando = true;
      final embedding = await _completer!.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          _capturando = false;
          throw 'No se pudo capturar el rostro. Mira de frente con buena luz.';
        },
      );

      // 2) Detener stream y tomar foto
      try {
        if (_cameraController != null && _cameraController!.value.isStreamingImages) {
          await _cameraController?.stopImageStream();
        }
      } catch (_) {}

      final XFile imageFile = await _cameraController!.takePicture();
      final bytes = await imageFile.readAsBytes();

      final String fileName = '$cedula.jpg';
      await Supabase.instance.client.storage
          .from('empleados_fotos')
          .uploadBinary(fileName, bytes, fileOptions: const FileOptions(upsert: true));

      final String fotoUrl = Supabase.instance.client.storage
          .from('empleados_fotos')
          .getPublicUrl(fileName);

      // 3) Guardar vía RPC protegida con PIN
      await Supabase.instance.client.rpc('enrolar_empleado', params: {
        'p_pin': pin,
        'p_cedula': cedula,
        'p_nombre': nombre,
        'p_apellido': apellido,
        'p_foto_url': fotoUrl,
        'p_embedding': jsonEncode(embedding),
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('¡Enrolamiento biométrico completado!')));
      _cedulaController.clear();
      _nombreController.clear();
      _apellidoController.clear();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      _capturando = false;
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
        _iniciarVerificacionRostroAdmin();
      }
    }
  }

  InputDecoration _dec(String label) => InputDecoration(
        labelText: label,
        filled: true,
        fillColor: const Color(0xFF1E293B),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        title: Text('Panel Admin - Enrolamiento', style: GoogleFonts.plusJakartaSans(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Row(
          children: [
            Expanded(
              flex: 1,
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    TextField(
                      controller: _pinController,
                      obscureText: true,
                      style: const TextStyle(color: Colors.white),
                      decoration: _dec('PIN de administrador'),
                    ),
                    const SizedBox(height: 12),
                    TextField(controller: _cedulaController, style: const TextStyle(color: Colors.white), decoration: _dec('Cédula')),
                    const SizedBox(height: 12),
                    TextField(controller: _nombreController, style: const TextStyle(color: Colors.white), decoration: _dec('Nombre')),
                    const SizedBox(height: 12),
                    TextField(controller: _apellidoController, style: const TextStyle(color: Colors.white), decoration: _dec('Apellido')),
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: _rostroDetectadoAdmin ? const Color(0xFF065F46) : const Color(0xFF7F1D1D),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        _mensajeRostro,
                        style: GoogleFonts.plusJakartaSans(color: Colors.white, fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(_debug, style: GoogleFonts.plusJakartaSans(color: Colors.amberAccent, fontSize: 11)),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton(
                        onPressed: (_isSaving || !_rostroDetectadoAdmin) ? null : _capturarYRegistrarEmpleado,
                        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2563EB)),
                        child: _isSaving
                            ? const CircularProgressIndicator(color: Colors.white)
                            : Text('Capturar y guardar', style: GoogleFonts.plusJakartaSans(color: Colors.white, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
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