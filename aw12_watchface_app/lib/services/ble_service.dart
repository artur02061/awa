import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:moyoung_ble_plugin/moyoung_ble.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Singleton service for managing BLE connection to AW12 watch
class BleService {
  static final BleService _instance = BleService._internal();
  factory BleService() => _instance;
  BleService._internal();

  final MoYoungBle blePlugin = MoYoungBle();
  bool _initialized = false;

  // State
  bool isConnected = false;
  bool isConnecting = false;
  String? connectedAddress;
  String? connectedName;
  int batteryLevel = -1;
  String firmwareVersion = '';

  // Stream controllers for UI updates
  final _connectionStateController = StreamController<bool>.broadcast();
  final _scanResultsController = StreamController<List<BleScanBean>>.broadcast();
  final _batteryController = StreamController<int>.broadcast();
  final _watchFaceProgressController = StreamController<int>.broadcast();
  final _errorController = StreamController<String>.broadcast();

  Stream<bool> get connectionState => _connectionStateController.stream;
  Stream<List<BleScanBean>> get scanResults => _scanResultsController.stream;
  Stream<int> get battery => _batteryController.stream;
  Stream<int> get watchFaceProgress => _watchFaceProgressController.stream;
  Stream<String> get errors => _errorController.stream;

  final List<BleScanBean> _devices = [];
  final List<StreamSubscription> _subscriptions = [];
  Timer? _connectionTimeout;

  // Prefs keys
  static const _keyLastAddress = 'last_device_address';
  static const _keyLastName = 'last_device_name';

  /// Initialize listeners (safe to call multiple times)
  void init() {
    if (_initialized) return;
    _initialized = true;

    // Scan listener
    _subscriptions.add(
      blePlugin.bleScanEveStm.listen((BleScanBean event) {
        if (event.isCompleted) {
          _scanResultsController.add(List.from(_devices));
        } else {
          if (!_devices.any((d) => d.address == event.address)) {
            _devices.add(event);
            _scanResultsController.add(List.from(_devices));
          }
        }
      }),
    );

    // Connection state listener
    _subscriptions.add(
      blePlugin.connStateEveStm.listen((ConnectStateBean event) {
        final wasConnected = isConnected;
        isConnected = event.connectState == 2; // stateConnected
        isConnecting = false;
        _connectionTimeout?.cancel();
        _connectionStateController.add(isConnected);

        if (isConnected) {
          _queryDeviceInfo();
          _saveLastDevice();
        } else if (wasConnected) {
          // Unexpected disconnect
          batteryLevel = -1;
          firmwareVersion = '';
          _errorController.add('Часы отключились');
        }
      }),
    );

    // Battery listener
    _subscriptions.add(
      blePlugin.deviceBatteryEveStm.listen((DeviceBatteryBean event) {
        if (event.type == 2) {
          batteryLevel = event.deviceBattery ?? -1;
          _batteryController.add(batteryLevel);
        }
      }),
    );

    // Watch face background transfer progress (per plugin docs: fileTransEveStm)
    _subscriptions.add(
      blePlugin.fileTransEveStm.listen((FileTransBean event) {
        _handleFileTransEvent(event);
      }),
    );

    // Watch face .bin file transfer progress
    _subscriptions.add(
      blePlugin.wfFileTransEveStm.listen((FileTransBean event) {
        _handleFileTransEvent(event);
      }),
    );
  }

  /// Handle file transfer events
  void _handleFileTransEvent(FileTransBean event) {
    // FileTransBean: type (int), progress (int?), error (int?)
    if (event.error != null && event.error! > 0) {
      _watchFaceProgressController.add(-1);
      _errorController.add('Ошибка передачи (код ${event.error})');
      return;
    }
    if (event.progress != null && event.progress! >= 0) {
      _watchFaceProgressController.add(event.progress!);
    }
  }

  // ──────────── Scanning ────────────

  Future<void> startScan() async {
    _devices.clear();
    _scanResultsController.add([]);
    try {
      await blePlugin.startScan(10 * 1000);
    } catch (e) {
      _errorController.add('Ошибка сканирования: $e');
    }
  }

  Future<void> stopScan() async {
    try {
      await blePlugin.cancelScan();
    } catch (_) {}
  }

  // ──────────── Connection ────────────

  /// Connect with a 15-second timeout
  Future<void> connect(String address, String name) async {
    if (isConnecting) return;
    isConnecting = true;
    connectedAddress = address;
    connectedName = name;

    _connectionTimeout?.cancel();
    _connectionTimeout = Timer(const Duration(seconds: 15), () {
      if (!isConnected && isConnecting) {
        isConnecting = false;
        _connectionStateController.add(false);
        _errorController.add('Таймаут подключения — попробуйте ещё раз');
      }
    });

    try {
      await blePlugin.connect(ConnectBean(
        autoConnect: true,
        address: address,
      ));
    } catch (e) {
      isConnecting = false;
      _connectionTimeout?.cancel();
      _errorController.add('Ошибка подключения: $e');
      _connectionStateController.add(false);
    }
  }

  Future<void> disconnect() async {
    _connectionTimeout?.cancel();
    try {
      await blePlugin.disconnect();
    } catch (_) {}
    isConnected = false;
    isConnecting = false;
    connectedAddress = null;
    connectedName = null;
    batteryLevel = -1;
    firmwareVersion = '';
    _connectionStateController.add(false);
  }

  /// Try reconnecting to the last saved device
  Future<bool> tryAutoReconnect() async {
    final saved = await getLastDevice();
    if (saved == null) return false;
    await connect(saved['address']!, saved['name']!);
    return true;
  }

  // ──────────── Device Info ────────────

  Future<void> _queryDeviceInfo() async {
    try {
      firmwareVersion = await blePlugin.queryFirmwareVersion();
    } catch (e) {
      print('Error querying firmware: $e');
    }
    try {
      await blePlugin.queryDeviceBattery();
    } catch (e) {
      print('Error querying battery: $e');
    }
  }

  // ──────────── Watch Face ────────────

  Future<int> getDisplayWatchFace() async {
    return await blePlugin.queryDisplayWatchFace;
  }

  Future<void> setDisplayWatchFace(int index) async {
    await blePlugin.sendDisplayWatchFace(index);
  }

  Future<WatchFaceLayoutBean> getWatchFaceLayout() async {
    return await blePlugin.queryWatchFaceLayout;
  }

  /// Send custom watch face background image.
  /// Loads, resizes to 240x240, converts to bitmap bytes.
  Future<void> sendWatchFaceBackground(String imagePath) async {
    final file = File(imagePath);
    if (!await file.exists()) {
      throw Exception('Файл не найден: $imagePath');
    }
    final bytes = await file.readAsBytes();

    final original = img.decodeImage(bytes);
    if (original == null) throw Exception('Не удалось прочитать изображение');

    // Resize main image and thumbnail
    final resized = img.copyResize(original, width: 240, height: 240);
    final thumbResized = img.copyResize(original, width: 80, height: 80);

    // Encode as PNG bytes for the plugin
    final bitmapBytes = Uint8List.fromList(img.encodePng(resized));
    final thumbBytes = Uint8List.fromList(img.encodePng(thumbResized));

    await blePlugin.sendWatchFaceBackground(
      WatchFaceBackgroundBean(
        bitmap: bitmapBytes,
        thumbBitmap: thumbBytes,
        type: 'image',
        thumbWidth: 80,
        thumbHeight: 80,
        width: 240,
        height: 240,
      ),
    );
  }

  /// Send a .bin watch face file.
  Future<void> sendWatchFace(String filePath, {int index = 0, int timeout = 120}) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('Файл не найден: $filePath');
    }
    await blePlugin.sendWatchFace(
      SendWatchFaceBean(
        watchFaceFlutterBean: CustomizeWatchFaceBean(
          index: index,
          file: filePath,
        ),
        timeout: timeout,
      ),
    );
  }

  // ──────────── Persistence ────────────

  Future<void> _saveLastDevice() async {
    if (connectedAddress == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyLastAddress, connectedAddress!);
    await prefs.setString(_keyLastName, connectedName ?? 'AW12');
  }

  Future<Map<String, String>?> getLastDevice() async {
    final prefs = await SharedPreferences.getInstance();
    final address = prefs.getString(_keyLastAddress);
    final name = prefs.getString(_keyLastName);
    if (address == null) return null;
    return {'address': address, 'name': name ?? 'AW12'};
  }

  Future<void> clearLastDevice() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyLastAddress);
    await prefs.remove(_keyLastName);
  }

  // ──────────── Cleanup ────────────

  void dispose() {
    _connectionTimeout?.cancel();
    for (var sub in _subscriptions) {
      sub.cancel();
    }
    _connectionStateController.close();
    _scanResultsController.close();
    _batteryController.close();
    _watchFaceProgressController.close();
    _errorController.close();
  }
}
