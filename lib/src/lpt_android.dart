/*
 * Based on libserialport (https://sigrok.org/wiki/Libserialport).
 *
 * Copyright (C) 2020 J-P Nurmi <jpnurmi@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as
 * published by the Free Software Foundation, either version 3 of the
 * License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

// ignore_for_file: annotate_overrides, unnecessary_getters_setters

import 'dart:typed_data';
import 'dart:async';

import 'package:usb_serial/usb_serial.dart';

import 'package:libserialport/src/config.dart';
import 'package:libserialport/src/enums.dart';
import 'package:libserialport/src/error.dart';
import 'package:libserialport/src/port.dart';
import 'package:libserialport/src/reader.dart';

/// [SerialPort]-compatible wrapper for **Android** parallel (LPT) ports over USB.
///
/// ## How it works
///
/// On Android, old parallel-port printers connect via USB adapters.
/// The Android OS exposes them through the **USB Host API** as USB Printer
/// Class devices (`bInterfaceClass = 0x07`).
///
/// This class uses the [`usb_serial`](https://pub.dev/packages/usb_serial)
/// package – the same one used by [SerialPortAndroid] – as a best-effort
/// transport layer.  It will work correctly for USB-to-parallel adapters
/// that expose a **CDC / serial** interface alongside (or instead of) the
/// printer class interface, which is common in many cheap adapters.
///
/// **For pure USB Printer Class (0x07) devices** a native Android plugin is
/// required (bulk transfer via `UsbDeviceConnection.bulkTransfer`).  This
/// class provides a drop-in skeleton: replace the [write] body with a
/// [MethodChannel] call to your native code when needed.
///
/// ## Port naming – `usblpt:N`
///
/// Because Android cannot enumerate USB printer class devices without native
/// code, [availablePorts] returns an **empty list**.
///
/// Identify the target device by calling `UsbSerial.listDevices()` in your
/// application to get the device index, then construct the port explicitly:
///
/// ```dart
/// final devices = await UsbSerial.listDevices();
/// // Inspect devices[0].productName, devices[0].vid/pid, etc.
///
/// final port = SerialPort('usblpt:0'); // open USB device at index 0
/// await port.openWrite();
/// await port.write(Uint8List.fromList([0x1B, 0x40])); // ESC @
/// await port.close();
/// ```
class SerialPortLptAndroid implements SerialPort {
  /// Index into the last device list returned by UsbSerial.listDevices().
  final int _deviceIndex;

  /// Optional interface number (default -1 → let usb_serial decide).
  final int _interfaceNumber;

  /// Cached copy of the device list from UsbSerial.
  static List<UsbDevice> _currentDevices = [];

  /// The underlying usb_serial port.
  UsbPort? _port;
  bool _portOpened = false;

  /// Read buffer for incoming data.
  Uint8List _dataAvailable = Uint8List(0);
  StreamSubscription? _reading;

  /// Most recent error message. Exposed via [SerialPort.lastError].
  static SerialPortError? _lastError;

  /// Creates an Android LPT port.
  ///
  /// [name] must follow the `usblpt:N` convention, e.g. `'usblpt:0'`.
  /// An optional interface number can be appended: `'usblpt:0+1'`.
  SerialPortLptAndroid(String name)
      : _deviceIndex = _parseIndex(name),
        _interfaceNumber = _parseInterface(name);

  /// @internal – used by reader factory.
  SerialPortLptAndroid.fromAddress(int address)
      : _deviceIndex = address & 0xff,
        _interfaceNumber = -1;

  static int _parseIndex(String name) {
    final suffix = name.toLowerCase().replaceFirst('usblpt:', '');
    final parts = suffix.split('+');
    return int.tryParse(parts[0]) ?? 0;
  }

  static int _parseInterface(String name) {
    final suffix = name.toLowerCase().replaceFirst('usblpt:', '');
    final parts = suffix.split('+');
    return parts.length >= 2 ? (int.tryParse(parts[1]) ?? -1) : -1;
  }

  // ── Static helpers ─────────────────────────────────────────────────────────

  /// Always returns an empty list on Android because USB Printer Class devices
  /// cannot be distinguished from other USB devices without native code.
  static Future<List<String>> get availablePorts async => [];

  /// Refreshes the internal USB device cache and returns it.
  ///
  /// This must be called before opening any 'usblpt:N' port if N > 0.
  static Future<List<UsbDevice>> listDevices() async {
    _currentDevices = await UsbSerial.listDevices();
    return List.unmodifiable(_currentDevices);
  }

  /// Gets the last error encountered by any Android LPT port operation.
  static SerialPortError? get lastError => _lastError;

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Resolves the current [_deviceIndex] against [_currentDevices].
  UsbDevice? get _device =>
      (_deviceIndex >= 0 && _deviceIndex < _currentDevices.length)
          ? _currentDevices[_deviceIndex]
          : null;

  /// Internal handler to pipe data from the UsbPort stream to our local buffer.
  void _startReading() {
    _dataAvailable = Uint8List(0);
    if (_port?.inputStream != null) {
      _reading = _port!.inputStream!.listen((Uint8List data) {
        final buf = BytesBuilder()
          ..add(_dataAvailable)
          ..add(data);
        _dataAvailable = buf.toBytes();
      });
    }
  }

  // ── SerialPort interface ───────────────────────────────────────────────────

  @override
  int get address => _device?.deviceId ?? _deviceIndex;

  @override
  String? get name => 'usblpt:$_deviceIndex';

  @override
  String? get description {
    final d = _device;
    if (d == null) return 'USB LPT device (index $_deviceIndex not found)';
    return '${d.productName ?? 'Unknown'} [VID:${d.vid?.toRadixString(16)} PID:${d.pid?.toRadixString(16)}]';
  }

  @override
  int get transport => SerialPortTransport.usb;

  @override
  int? get busNumber => -1;
  @override
  int? get deviceNumber => _device?.deviceId;
  @override
  int? get vendorId => _device?.vid;
  @override
  int? get productId => _device?.pid;
  @override
  String? get manufacturer => _device?.manufacturerName;
  @override
  String? get productName => _device?.productName;
  @override
  String? get serialNumber => _device?.serial;
  @override
  String? get macAddress => _device?.serial;

  @override
  bool get isOpen => _portOpened;

  @override
  void dispose() => close();

  @override
  Future<bool> open({required int mode}) async {
    _lastError = null;

    // Automatically refresh device list if it hasn't been populated yet.
    if (_currentDevices.isEmpty) {
      _currentDevices = await UsbSerial.listDevices();
    }

    final device = _device;
    if (device == null) {
      _lastError = SerialPortError(
        'USB LPT device at index $_deviceIndex not found. '
        'Call SerialPortLptAndroid.listDevices() first.',
        -1,
      );
      return false;
    }

    // Attempt to open as a generic CDC device.
    final p = await device.create('', _interfaceNumber);
    if (p == null) {
      _lastError = SerialPortError(
        'Could not create USB port for "${device.productName}". '
        'Device might require native USB Printer Class (0x07) support.',
        -1,
      );
      return false;
    }

    _port = p;
    _portOpened = await _port!.open();
    return _portOpened;
  }

  @override
  Future<bool> openRead() => open(mode: SerialPortMode.read);
  @override
  Future<bool> openWrite() => open(mode: SerialPortMode.write);
  @override
  Future<bool> openReadWrite() => open(mode: SerialPortMode.readWrite);

  @override
  Future<bool> close() async {
    await _reading?.cancel();
    _reading = null;
    if (_portOpened && _port != null) {
      final result = await _port!.close();
      _portOpened = !result;
      return result;
    }
    return false;
  }

  SerialPortConfig? _config;

  @override
  SerialPortConfig get config => _config ??= SerialPortConfig();

  @override
  Future<void> setConfig(SerialPortConfig config) async {
    _config = config;
    if (_port == null) return;
    // Android USB adapters might ignore baud rate / stop bits,
    // but CDC-compliant ones will apply these.
    try {
      await _port!.setDTR(config.dtr == SerialPortDtr.on);
      await _port!.setPortParameters(
        config.baudRate,
        config.bits,
        config.stopBits,
        config.parity,
      );
    } catch (_) { /* ignore serial-unfriendly adapters */ }
  }

  @override
  Future<int> write(Uint8List bytes, {int timeout = -1}) async {
    if (_port == null || !_portOpened) {
      _lastError = SerialPortError('Port is not open', -1);
      return -1;
    }
    _lastError = null;
    try {
      await _port!.write(bytes);
      return bytes.length;
    } catch (e) {
      _lastError = SerialPortError(e.toString(), -1);
      return -1;
    }
  }

  @override
  Future<Uint8List> read(int bytes, {int timeout = -1}) async {
    // Lazy-start the internal reading stream.
    if (_reading == null) _startReading();

    // Consume from the cached buffer first.
    if (_dataAvailable.length >= bytes) {
      final sub = _dataAvailable.sublist(0, bytes);
      _dataAvailable = _dataAvailable.sublist(bytes);
      return sub;
    }

    // Blocking read with timeout.
    if (timeout >= 0) {
      var elapsed = 0;
      while (elapsed < timeout) {
        await Future.delayed(const Duration(milliseconds: 1));
        elapsed++;
        if (_dataAvailable.length >= bytes) {
          final sub = _dataAvailable.sublist(0, bytes);
          _dataAvailable = _dataAvailable.sublist(bytes);
          return sub;
        }
      }
    }

    return Uint8List(0);
  }

  @override
  int get bytesAvailable => _dataAvailable.length;
  @override
  int get bytesToWrite => 0;

  @override
  void flush([int buffers = SerialPortBuffer.both]) {
    // For Android reading, flush clears our local byte cache.
    _dataAvailable = Uint8List(0);
  }

  @override
  void drain() {/* no-op on USB */}

  @override
  int get signals => 0;
  @override
  bool startBreak() => false;
  @override
  bool endBreak() => false;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SerialPortLptAndroid && _deviceIndex == other._deviceIndex;

  @override
  int get hashCode => _deviceIndex.hashCode;

  @override
  String toString() => 'SerialPortLptAndroid(usblpt:$_deviceIndex)';
}

/// [SerialPortReader] implementation for Android LPT ports.
/// Directly pipes the UsbPort inputStream to the stream.
class SerialPortReaderLptAndroid implements SerialPortReader {
  final SerialPortLptAndroid _port;
  StreamSubscription? _subscription;
  StreamController<Uint8List>? _controller;

  SerialPortReaderLptAndroid(this._port);

  @override
  SerialPort get port => _port;

  @override
  Stream<Uint8List> get stream {
    _controller = StreamController<Uint8List>(
      onListen: () {
        if (_port._port?.inputStream != null) {
          _subscription = _port._port!.inputStream!.listen((data) {
            _controller?.add(data);
          });
        }
      },
      onCancel: () => _subscription?.cancel(),
    );
    return _controller!.stream;
  }

  @override
  void close() {
    _subscription?.cancel();
    _controller?.close();
  }
}
