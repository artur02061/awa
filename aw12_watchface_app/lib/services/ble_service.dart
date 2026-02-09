import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:image/image.dart' as img;
import 'package:moyoung_ble_plugin/moyoung_ble.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Simple model for discovered BLE devices
class DiscoveredDevice {
  final String name;
  final String address;
  final int rssi;
  final String source; // 'fbp' or 'moyoung' — for debugging

  DiscoveredDevice({
    required this.name,
    required this.address,
    required this.rssi,
    this.source = '',
  });
}

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
  final _scanResultsController = StreamController<List<DiscoveredDevice>>.broadcast();
  final _batteryController = StreamController<int>.broadcast();
  final _watchFaceProgressController = StreamController<int>.broadcast();
  final _errorController = StreamController<String>.broadcast();

  Stream<bool> get connectionState => _connectionStateController.stream;
  Stream<List<DiscoveredDevice>> get scanResults => _scanResultsController.stream;
  Stream<int> get battery => _batteryController.stream;
  Stream<int> get watchFaceProgress => _watchFaceProgressController.stream;
  Stream<String> get errors => _errorController.stream;

  final List<DiscoveredDevice> _devices = [];
  final List<StreamSubscription> _subscriptions = [];
  Timer? _connectionTimeout;
  bool _continuousScanning = false;
  StreamSubscription? _fbpScanSubscription;

  // Prefs keys
  static const _keyLastAddress = 'last_device_address';
  static const _keyLastName = 'last_device_name';

  /// Initialize listeners (safe to call multiple times)
  void init() {
    if (_initialized) return;
    _initialized = true;

    // MoYoung scan listener — catch devices from plugin's own scan
    _subscriptions.add(
      blePlugin.bleScanEveStm.listen((BleScanBean event) {
        if (!event.isCompleted) {
          _addDevice(
            name: event.name ?? '',
            address: event.address ?? '',
            rssi: -60, // moyoung doesn't expose rssi
            source: 'moyoung',
          );
        }
      }),
    );

    // Connection state listener (moyoung plugin)
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

    // Watch face background transfer progress
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

  /// Add a device to list (deduplicated by address)
  void _addDevice({
    required String name,
    required String address,
    required int rssi,
    required String source,
  }) {
    if (address.isEmpty) return;
    if (_devices.any((d) => d.address == address)) return;
    _devices.add(DiscoveredDevice(
      name: name,
      address: address,
      rssi: rssi,
      source: source,
    ));
    _scanResultsController.add(List.from(_devices));
  }

  /// Handle file transfer events
  void _handleFileTransEvent(FileTransBean event) {
    if (event.error != null && event.error! > 0) {
      _watchFaceProgressController.add(-1);
      _errorController.add('Ошибка передачи (код ${event.error})');
      return;
    }
    if (event.progress != null && event.progress! >= 0) {
      _watchFaceProgressController.add(event.progress!);
    }
  }

  // ──────────── Scanning (dual: flutter_blue_plus + moyoung) ────────────

  bool get isScanning => _continuousScanning;

  Future<void> startScan() async {
    _devices.clear();
    _scanResultsController.add([]);
    _continuousScanning = true;

    // --- FlutterBluePlus scan (all BLE devices) ---
    _fbpScanSubscription?.cancel();
    _fbpScanSubscription = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        final address = r.device.remoteId.str;
        final name = r.device.platformName.isNotEmpty
            ? r.device.platformName
            : r.advertisementData.advName;
        _addDevice(
          name: name,
          address: address,
          rssi: r.rssi,
          source: 'fbp',
        );
      }
    });

    // Start FlutterBluePlus scan (non-blocking — don't await)
    _startFbpScan();

    // --- MoYoung scan in parallel (filtered to compatible watches) ---
    _startMoyoungScan();
  }

  /// Start/restart FlutterBluePlus scan cycle
  Future<void> _startFbpScan() async {
    if (!_continuousScanning) return;
    try {
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 30),
        androidUsesFineLocation: true,
      );
      // Cycle finished — restart if still active
      if (_continuousScanning) {
        _startFbpScan();
      }
    } catch (e) {
      print('FlutterBluePlus scan error: $e');
      // Don't stop _continuousScanning — moyoung scan may still work
    }
  }

  /// Start/restart MoYoung plugin scan cycle
  Future<void> _startMoyoungScan() async {
    if (!_continuousScanning) return;
    try {
      await blePlugin.startScan(30 * 1000);
      // Scan completed — restart if still active
      if (_continuousScanning) {
        _startMoyoungScan();
      }
    } catch (e) {
      print('MoYoung scan error: $e');
      // Don't stop — fbp scan may still work
    }
  }

  Future<void> stopScan() async {
    _continuousScanning = false;
    _fbpScanSubscription?.cancel();
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    try {
      await blePlugin.cancelScan;
    } catch (_) {}
  }

  // ──────────── Connection (moyoung plugin) ────────────

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
        autoConnect: false,
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
      await blePlugin.disconnect;
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
      firmwareVersion = await blePlugin.queryFirmwareVersion;
    } catch (e) {
      print('Error querying firmware: $e');
    }
    try {
      await blePlugin.queryDeviceBattery;
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
  Future<void> sendWatchFaceBackground(String imagePath) async {
    final file = File(imagePath);
    if (!await file.exists()) {
      throw Exception('Файл не найден: $imagePath');
    }
    final bytes = await file.readAsBytes();

    final original = img.decodeImage(bytes);
    if (original == null) throw Exception('Не удалось прочитать изображение');

    final resized = img.copyResize(original, width: 240, height: 240);
    final thumbResized = img.copyResize(original, width: 80, height: 80);

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
    _fbpScanSubscription?.cancel();
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
