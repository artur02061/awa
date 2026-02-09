import 'dart:async';
import 'package:flutter/material.dart';
import 'package:moyoung_ble_plugin/moyoung_ble.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/ble_service.dart';
import 'watchface_gallery_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({Key? key}) : super(key: key);

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final BleService _bleService = BleService();
  List<BleScanBean> _devices = [];
  bool _isScanning = false;
  bool _isConnected = false;
  bool _isConnecting = false;
  int _battery = -1;
  String? _lastDeviceName;
  String? _lastDeviceAddress;
  final List<StreamSubscription> _subs = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bleService.init();
    _setupListeners();
    _loadLastDevice();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // When app comes back to foreground, refresh connection state
    if (state == AppLifecycleState.resumed && _isConnected) {
      try {
        _bleService.blePlugin.queryDeviceBattery;
      } catch (_) {}
    }
  }

  void _setupListeners() {
    _subs.add(_bleService.scanResults.listen((devices) {
      if (!mounted) return;
      setState(() => _devices = devices);
    }));

    _subs.add(_bleService.connectionState.listen((connected) {
      if (!mounted) return;
      if (connected) {
        _bleService.stopScan();
      }
      setState(() {
        _isConnected = connected;
        _isConnecting = _bleService.isConnecting;
        if (connected) {
          _isScanning = false;
        }
      });
      if (connected) {
        _showSnackBar('Подключено к ${_bleService.connectedName}!', Colors.green);
      }
    }));

    _subs.add(_bleService.battery.listen((level) {
      if (!mounted) return;
      setState(() => _battery = level);
    }));

    _subs.add(_bleService.errors.listen((error) {
      if (!mounted) return;
      setState(() {
        _isConnecting = false;
        _isScanning = false;
      });
      _showSnackBar(error, Colors.redAccent);
    }));
  }

  Future<void> _loadLastDevice() async {
    final saved = await _bleService.getLastDevice();
    if (saved != null && mounted) {
      setState(() {
        _lastDeviceName = saved['name'];
        _lastDeviceAddress = saved['address'];
      });
    }
  }

  Future<bool> _requestPermissions() async {
    try {
      // Check if Bluetooth adapter is turned on
      final btServiceStatus = await Permission.bluetooth.serviceStatus;
      if (btServiceStatus != ServiceStatus.enabled) {
        if (mounted) {
          _showSnackBar(
            'Включите Bluetooth для поиска часов',
            Colors.orange,
          );
        }
        return false;
      }

      // Check if Location services are enabled (required for BLE scanning on Android)
      final locationServiceStatus = await Permission.location.serviceStatus;
      if (locationServiceStatus != ServiceStatus.enabled) {
        if (mounted) {
          _showSnackBar(
            'Включите геолокацию — Android требует её для поиска Bluetooth-устройств',
            Colors.orange,
          );
        }
        return false;
      }

      final statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.location,
      ].request();

      final denied = statuses.entries
          .where((e) => e.value.isDenied || e.value.isPermanentlyDenied)
          .toList();

      if (denied.isNotEmpty) {
        if (mounted) {
          final permanentlyDenied = denied.any((e) => e.value.isPermanentlyDenied);
          _showSnackBar(
            permanentlyDenied
                ? 'Откройте настройки и разрешите доступ к Bluetooth и геолокации'
                : 'Для работы нужны разрешения Bluetooth и геолокации',
            Colors.orange,
            action: permanentlyDenied
                ? SnackBarAction(
                    label: 'Настройки',
                    textColor: Colors.white,
                    onPressed: () => openAppSettings(),
                  )
                : null,
          );
        }
        return false;
      }
      return true;
    } catch (e) {
      if (mounted) {
        _showSnackBar(
          'Ошибка при запросе разрешений: $e',
          Colors.redAccent,
        );
      }
      return false;
    }
  }

  Future<void> _startScan() async {
    final ok = await _requestPermissions();
    if (!ok) return;

    setState(() {
      _isScanning = true;
      _devices = [];
    });

    try {
      await _bleService.startScan();
    } catch (e) {
      if (mounted) {
        setState(() => _isScanning = false);
        _showSnackBar('Ошибка запуска поиска: $e', Colors.redAccent);
      }
    }
  }

  Future<void> _stopScan() async {
    await _bleService.stopScan();
    if (mounted) {
      setState(() => _isScanning = false);
    }
  }

  Future<void> _connectToDevice(String address, String name) async {
    if (_isConnecting) return;
    setState(() {
      _isConnecting = true;
      _isScanning = false;
    });
    await _bleService.stopScan();
    await _bleService.connect(address, name);
  }

  Future<void> _reconnectLastDevice() async {
    if (_lastDeviceAddress == null || _isConnecting) return;
    final ok = await _requestPermissions();
    if (!ok) return;
    setState(() => _isConnecting = true);
    await _bleService.connect(_lastDeviceAddress!, _lastDeviceName ?? 'AW12');
  }

  Future<void> _forgetDevice() async {
    await _bleService.clearLastDevice();
    setState(() {
      _lastDeviceName = null;
      _lastDeviceAddress = null;
    });
    _showSnackBar('Устройство забыто', Colors.grey);
  }

  void _showSnackBar(String message, Color color, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color.withValues(alpha: 0.9),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        action: action,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (var sub in _subs) {
      sub.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '⌚ AW12 Циферблаты',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          if (_isConnected && _battery > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _battery > 50
                        ? Icons.battery_full
                        : _battery > 20
                            ? Icons.battery_3_bar
                            : Icons.battery_1_bar,
                    color: _battery > 20 ? Colors.tealAccent : Colors.red,
                    size: 20,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${_battery.clamp(0, 100)}%',
                    style: TextStyle(
                      color: _battery > 20 ? Colors.tealAccent : Colors.red,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
      body: _isConnected ? _buildConnectedView() : _buildScanView(),
    );
  }

  // ──────────── Connected View ────────────

  Widget _buildConnectedView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0xFF2A2A3E),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.tealAccent.withValues(alpha: 0.3)),
              ),
              child: Column(
                children: [
                  const Icon(Icons.watch, size: 64, color: Colors.tealAccent),
                  const SizedBox(height: 16),
                  Text(
                    _bleService.connectedName ?? 'AW12',
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Colors.tealAccent,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Подключено',
                        style: TextStyle(
                          fontSize: 16,
                          color: Colors.tealAccent.withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                  ),
                  if (_bleService.firmwareVersion.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Прошивка: ${_bleService.firmwareVersion}',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                  if (_battery > 0) ...[
                    const SizedBox(height: 12),
                    _buildBatteryBar(),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 32),

            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const WatchFaceGalleryScreen(),
                    ),
                  );
                },
                icon: const Icon(Icons.palette, size: 28),
                label: const Text(
                  'Выбрать циферблат',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            const SizedBox(height: 16),

            TextButton.icon(
              onPressed: () async {
                await _bleService.disconnect();
              },
              icon: const Icon(Icons.bluetooth_disabled, color: Colors.redAccent),
              label: const Text(
                'Отключиться',
                style: TextStyle(color: Colors.redAccent),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBatteryBar() {
    final level = _battery.clamp(0, 100);
    final color = level > 50
        ? Colors.tealAccent
        : level > 20
            ? Colors.orange
            : Colors.red;
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.battery_std, size: 16, color: color),
            const SizedBox(width: 4),
            Text(
              '$level%',
              style: TextStyle(color: color, fontSize: 13),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: level / 100,
            backgroundColor: Colors.white12,
            valueColor: AlwaysStoppedAnimation(color),
            minHeight: 4,
          ),
        ),
      ],
    );
  }

  // ──────────── Scan View ────────────

  Widget _buildScanView() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 20),
          const Text(
            'Найдите ваши часы',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Убедитесь что Bluetooth включён\nи часы рядом',
            style: TextStyle(
              fontSize: 14,
              color: Colors.white.withValues(alpha: 0.6),
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),

          // Quick reconnect card
          if (_lastDeviceAddress != null && !_isConnected)
            _buildLastDeviceCard(),

          const SizedBox(height: 12),

          // Scan button
          SizedBox(
            height: 50,
            child: _isScanning
                ? OutlinedButton.icon(
                    onPressed: _isConnecting ? null : _stopScan,
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.tealAccent),
                      foregroundColor: Colors.tealAccent,
                    ),
                    icon: const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.tealAccent,
                      ),
                    ),
                    label: const Text('Остановить поиск'),
                  )
                : ElevatedButton.icon(
                    onPressed: _isConnecting ? null : _startScan,
                    icon: const Icon(Icons.bluetooth_searching),
                    label: const Text('Начать поиск'),
                  ),
          ),
          const SizedBox(height: 20),

          if (_devices.isNotEmpty)
            Text(
              'Найденные устройства (${_devices.length}):',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Colors.white70,
              ),
            ),
          const SizedBox(height: 8),

          Expanded(
            child: _devices.isEmpty
                ? _buildEmptyState()
                : _buildDeviceList(),
          ),
        ],
      ),
    );
  }

  Widget _buildLastDeviceCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.tealAccent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.tealAccent.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          const Icon(Icons.watch, color: Colors.tealAccent, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _lastDeviceName ?? 'AW12',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  'Последнее устройство',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          if (_isConnecting)
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else ...[
            IconButton(
              icon: Icon(Icons.close, color: Colors.white.withValues(alpha: 0.4), size: 18),
              onPressed: _forgetDevice,
              tooltip: 'Забыть',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
            const SizedBox(width: 4),
            ElevatedButton(
              onPressed: _reconnectLastDevice,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              ),
              child: const Text('Подключить'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.watch_outlined,
            size: 80,
            color: Colors.white.withValues(alpha: 0.15),
          ),
          const SizedBox(height: 16),
          Text(
            _isScanning
                ? 'Ищем устройства...'
                : 'Нажмите "Начать поиск"',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.4),
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceList() {
    // Sort: AW12 devices first
    final sorted = List<BleScanBean>.from(_devices);
    sorted.sort((a, b) {
      final aIsAW = (a.name ?? '').toUpperCase().contains('AW12') ? 0 : 1;
      final bIsAW = (b.name ?? '').toUpperCase().contains('AW12') ? 0 : 1;
      return aIsAW.compareTo(bIsAW);
    });

    return ListView.builder(
      itemCount: sorted.length,
      itemBuilder: (context, index) {
        final device = sorted[index];
        final name = device.name ?? 'Неизвестное устройство';
        final isAW12 = name.toUpperCase().contains('AW12');
        final isThisConnecting =
            _isConnecting && _bleService.connectedAddress == device.address;

        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: isAW12
                  ? Colors.tealAccent.withValues(alpha: 0.2)
                  : Colors.white.withValues(alpha: 0.1),
              child: Icon(
                isAW12 ? Icons.watch : Icons.bluetooth,
                color: isAW12 ? Colors.tealAccent : Colors.white54,
              ),
            ),
            title: Text(
              name,
              style: TextStyle(
                color: Colors.white,
                fontWeight: isAW12 ? FontWeight.bold : FontWeight.normal,
              ),
            ),
            subtitle: Text(
              device.address ?? '',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
            ),
            trailing: isThisConnecting
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : ElevatedButton(
                    onPressed: _isConnecting
                        ? null
                        : () => _connectToDevice(
                              device.address!,
                              device.name ?? 'Unknown',
                            ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor:
                          isAW12 ? Colors.tealAccent : Colors.white24,
                    ),
                    child: const Text('Подключить'),
                  ),
            onTap: _isConnecting
                ? null
                : () => _connectToDevice(
                      device.address!,
                      device.name ?? 'Unknown',
                    ),
          ),
        );
      },
    );
  }
}
