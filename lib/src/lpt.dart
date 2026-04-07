/*
 * Based on libserialport (https://sigrok.org/wiki/Libserialport).
 *
 * Copyright (C) 2010-2012 Bert Vermeulen <bert@biot.com>
 * Copyright (C) 2010-2015 Uwe Hermann <uwe@hermann-uwe.de>
 * Copyright (C) 2013-2015 Martin Ling <martin-libserialport@earth.li>
 * Copyright (C) 2013 Matthias Heidbrink <m-sigrok@heidbrink.biz>
 * Copyright (C) 2014 Aurelien Jacobs <aurel@gnuage.org>
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

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:libserialport/src/config.dart';
import 'package:libserialport/src/enums.dart';
import 'package:libserialport/src/error.dart';
import 'package:libserialport/src/port.dart';
import 'package:libserialport/src/reader.dart';

/// Internal logging helper that mimics LIBSERIALPORT_DEBUG behavior.
void _log(String msg) {
  if (Platform.environment.containsKey('LIBSERIALPORT_DEBUG')) {
    stderr.writeln('libserialport (LPT): $msg');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers (exported so consumers can use them)
// ─────────────────────────────────────────────────────────────────────────────

/// Returns `true` when [name] refers to a parallel (LPT) port on any
/// supported platform.
///
/// Recognised patterns:
/// | Pattern                | Platform      |
/// |------------------------|---------------|
/// | `lpt`, `lpt0`…`lpt9`  | All (alias)   |
/// | `/dev/lp0`…`/dev/lp3` | Linux         |
/// | `/dev/usb/lp0`…`lp3`  | Linux (USB)   |
/// | `\\.\LPT1`…`\\.\LPT9` | Windows       |
/// | `usblpt:0`…`usblpt:N` | Android       |
bool isLptPort(String name) {
  final lower = name.toLowerCase();
  // Short / alias names: lpt, lpt0, lpt1 …
  if (RegExp(r'^lpt\d*$').hasMatch(lower)) return true;
  // Linux character device paths
  if (RegExp(r'^/dev/(usb/)?lp\d+$').hasMatch(lower)) return true;
  // Windows UNC device path (\\.\LPT1)
  if (lower.startsWith('\\\\.\\lpt')) return true;
  // Android USB index notation
  if (lower.startsWith('usblpt:')) return true;
  return false;
}

/// Converts a convenience port name to the canonical device path for the
/// current operating system.
///
/// | Input   | Linux output  | Windows output |
/// |---------|---------------|----------------|
/// | `lpt0`  | `/dev/lp0`    | `\\.\LPT1`     |
/// | `lpt1`  | `/dev/lp1`    | `\\.\LPT1`     |
/// | `lpt2`  | `/dev/lp2`    | `\\.\LPT2`     |
///
/// Paths that already use the full OS-specific form are returned unchanged.
///
/// **Note:** Windows LPT ports are 1-based (`LPT1`…`LPT9`).  `lpt0` is
/// treated as an alias for `LPT1` on Windows.
String lptToDevicePath(String name) {
  final lower = name.toLowerCase();
  final shortMatch = RegExp(r'^lpt(\d*)$').firstMatch(lower);
  if (shortMatch != null) {
    final numStr = shortMatch.group(1)!;
    final num = numStr.isEmpty ? 0 : int.parse(numStr);
    if (Platform.isWindows) {
      // Windows is 1-based; lpt0 ≡ LPT1.
      final winNum = num == 0 ? 1 : num;
      return '\\\\.\\LPT$winNum';
    } else {
      // Linux / macOS: 0-based
      return '/dev/lp$num';
    }
  }
  return name; // already a full path
}

// ─────────────────────────────────────────────────────────────────────────────
// Desktop implementation  (Linux · Windows · macOS)
// ─────────────────────────────────────────────────────────────────────────────

/// [SerialPort]-compatible wrapper for **desktop** parallel (LPT) ports.
///
/// | Platform | Device path           | Notes                          |
/// |----------|-----------------------|--------------------------------|
/// | Linux    | `/dev/lp0`…`/dev/lp3` | Kernel `lp` driver             |
/// | Linux    | `/dev/usb/lp0`…`lp3`  | USB parallel adapter           |
/// | Windows  | `\\.\LPT1`…`\\.\LPT9`| Win32 device file              |
/// | macOS    | —                     | Not natively supported         |
///
/// Hardware LPT ports on Linux are **write-only**; [read] always returns an
/// empty [Uint8List].  Configuration (baud rate, parity etc.) is not
/// applicable and is silently accepted but ignored.
class SerialPortLpt implements SerialPort {
  final String _devicePath;
  RandomAccessFile? _file;
  bool _isOpen = false;
  SerialPortConfig? _config;

  /// Stores the most recent error.  Exposed via [SerialPort.lastError].
  static SerialPortError? _lastError;

  SerialPortLpt(String name) : _devicePath = lptToDevicePath(name);

  /// @internal – not meaningful for LPT; kept for interface compatibility.
  SerialPortLpt.fromAddress(int address)
      : _devicePath =
            Platform.isWindows ? '\\\\.\\LPT${(address & 0xff) + 1}' : '/dev/lp${address & 0xff}';

  // ── Static helpers ─────────────────────────────────────────────────────────

  /// Lists all parallel ports that appear accessible on the system.
  ///
  /// * **Linux** – probes `/dev/lp0`…`/dev/lp3` and `/dev/usb/lp0`…`/dev/usb/lp3`
  ///   for existence.
  /// * **Windows** – attempts to briefly open `\\.\LPT1`…`\\.\LPT9`.
  static Future<List<String>> get availablePorts async {
    if (Platform.isLinux) {
      return _linuxPorts();
    } else if (Platform.isWindows) {
      return _windowsPorts();
    }
    return [];
  }

  static Future<List<String>> _linuxPorts() async {
    final candidates = [
      for (var i = 0; i < 4; i++) '/dev/lp$i',
      for (var i = 0; i < 4; i++) '/dev/usb/lp$i',
    ];
    final result = <String>[];
    for (final path in candidates) {
      // On Linux, character device files listed in /dev can be safely
      // probed for existence without side effects.
      if (await File(path).exists()) result.add(path);
    }
    return result;
  }

  /// Detects Windows LPT ports by briefly attempting to open each candidate.
  static Future<List<String>> _windowsPorts() async {
    final result = <String>[];
    for (var i = 1; i <= 9; i++) {
      final path = '\\\\.\\LPT$i';
      try {
        // On Windows, device paths like \\.\LPT1 cannot be checked via
        // File.exists().  We must attempt to open them.
        final f = await File(path).open(mode: FileMode.write);
        await f.close();
        result.add(path);
      } catch (_) {
        // Port does not exist, is busy, or requires higher privileges.
      }
    }
    return result;
  }

  /// Gets the last error encountered by any LPT port operation.
  static SerialPortError? get lastError => _lastError;

  // ── SerialPort interface ───────────────────────────────────────────────────

  @override
  int get address => _devicePath.hashCode;

  @override
  String? get name => _devicePath;

  @override
  String? get description => 'Parallel port ($_devicePath)';

  @override
  int get transport => SerialPortTransport.native;

  @override
  int? get busNumber => null;
  @override
  int? get deviceNumber => null;
  @override
  int? get vendorId => null;
  @override
  int? get productId => null;
  @override
  String? get manufacturer => null;
  @override
  String? get productName => null;
  @override
  String? get serialNumber => null;
  @override
  String? get macAddress => null;

  @override
  bool get isOpen => _isOpen;

  @override
  void dispose() {
    if (_isOpen) close();
    _config?.dispose();
  }

  @override
  Future<bool> open({required int mode}) async {
    _lastError = null;
    try {
      final file = File(_devicePath);

      // On Linux we can test existence cheaply; on Windows device paths
      // File.exists() always returns false, so we skip the check.
      if (Platform.isLinux && !await file.exists()) {
        _log('Device file not found: $_devicePath');
        _lastError = SerialPortError(
          'Parallel port device not found: $_devicePath  '
          '(check that the kernel module is loaded: lsmod | grep -E "lp|usblp")',
          -1,
        );
        return false;
      }

      // Use FileMode.write (O_WRONLY|O_CREAT|O_TRUNC).
      // On Linux/Windows, O_TRUNC is typically a no-op for character devices,
      // but it's the standard mode for write-only access in dart:io.
      _log('Opening $_devicePath (write mode)');
      _file = await file.open(mode: FileMode.write);
      _isOpen = true;
      _log('Opened $_devicePath successfully (fd is valid)');
      return true;
    } on FileSystemException catch (e) {
      _log('Failed to open $_devicePath: ${e.message} (OS Error: ${e.osError})');
      final hint = _permissionHint(e);
      _lastError = SerialPortError(
        '${e.message}: $_devicePath$hint',
        e.osError?.errorCode ?? -1,
      );
      return false;
    } catch (e) {
      _log('Failed to open $_devicePath (unknown error): $e');
      _lastError = SerialPortError(e.toString(), -1);
      return false;
    }
  }

  /// Provides context-aware hints for common LPT access errors.
  static String _permissionHint(FileSystemException e) {
    final code = e.osError?.errorCode;
    if (code == 13 /* EACCES */ || code == 1 /* EPERM */) {
      if (Platform.isLinux) {
        return '\n  Hint: add your user to the lp group:\n'
            '  sudo usermod -a -G lp \$USER && newgrp lp';
      }
    }
    if (code == 16 /* EBUSY */) {
      return '\n  Hint: the port is busy (another process has it open).';
    }
    return '';
  }

  @override
  Future<bool> openRead() => open(mode: SerialPortMode.read);
  @override
  Future<bool> openWrite() => open(mode: SerialPortMode.write);
  @override
  Future<bool> openReadWrite() => open(mode: SerialPortMode.readWrite);

  @override
  Future<bool> close() async {
    _log('Closing $_devicePath');
    try {
      await _file?.close();
    } catch (_) {}
    _file = null;
    _isOpen = false;
    return true;
  }

  @override
  SerialPortConfig get config => _config ??= SerialPortConfig();

  @override
  Future<void> setConfig(SerialPortConfig config) async {
    if (_config != config) _config?.dispose();
    _config = config;
    // Parallel ports do not have serial baud rate/parity/stopbits etc.
    // We accept the config object but ignore its fields for compatibility.
  }

  @override
  Future<int> write(Uint8List bytes, {int timeout = -1}) async {
    if (_file == null || !_isOpen) {
      _lastError = SerialPortError('Port is not open', -1);
      return -1;
    }
    _lastError = null;
    try {
      _log('Writing ${bytes.length} bytes to $_devicePath');
      await _file!.writeFrom(bytes);

      // Flush immediately — for character devices like /dev/lp* the kernel
      // may buffer the data until explicitly flushed or the fd is closed.
      await _file!.flush();
      _log('Write and flush completed');
      return bytes.length;
    } on FileSystemException catch (e) {
      _log('Write failed to $_devicePath: ${e.message}');
      _lastError = SerialPortError(
        '${e.message}: $_devicePath',
        e.osError?.errorCode ?? -1,
      );
      return -1;
    } catch (e) {
      _log('Write failed to $_devicePath (unknown error): $e');
      _lastError = SerialPortError(e.toString(), -1);
      return -1;
    }
  }

  @override
  Future<Uint8List> read(int bytes, {int timeout = -1}) async {
    _log('Read requested on $_devicePath ($bytes bytes) - not supported');
    // Standard LPT device drivers in Linux/Windows usually do not support
    // bi-directional data flow via basic character device files.
    return Uint8List(0);
  }

  @override
  int get bytesAvailable => 0;
  @override
  int get bytesToWrite => 0;

  @override
  void flush([int buffers = SerialPortBuffer.both]) => _file?.flushSync();
  @override
  void drain() => _file?.flushSync();

  @override
  int get signals => 0;
  @override
  bool startBreak() => false;
  @override
  bool endBreak() => false;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SerialPortLpt && _devicePath == other._devicePath;

  @override
  int get hashCode => _devicePath.hashCode;

  @override
  String toString() => 'SerialPortLpt($_devicePath)';
}

/// [SerialPortReader] implementation for LPT ports.
///
/// LPT ports on desktop platforms do not support reading data.
/// This implementation provides an empty stream.
class SerialPortReaderLpt implements SerialPortReader {
  final SerialPort _port;
  final StreamController<Uint8List> _controller = StreamController<Uint8List>();

  SerialPortReaderLpt(this._port) {
    _controller.close(); // Immediately close as read is not supported
  }

  @override
  SerialPort get port => _port;

  @override
  Stream<Uint8List> get stream => _controller.stream;

  @override
  void close() {}
}

extension SerialPortLptReader on SerialPortLpt {
  /// Provides access to an LPT-compatible reader.
  SerialPortReader get reader => SerialPortReaderLpt(this);
}
