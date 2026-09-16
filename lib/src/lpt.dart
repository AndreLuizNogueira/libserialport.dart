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

/// Matches a Linux USB printer-class device node (`usblp` driver).
final _kUsbPrinterPath = RegExp(r'^/dev/(usb/lp|usblp)(\d+)$');

/// Returns `true` when [name] refers to a parallel (LPT) or USB printer-class
/// port on any supported platform.
///
/// Two distinct device families are recognised.  They are **not**
/// interchangeable: on Linux they are handled by different kernel drivers and
/// are numbered independently, so `/dev/lp0` and `/dev/usb/lp0` may well be two
/// different printers on the same machine.
///
/// **Parallel port** (IEEE-1284, `parport`+`lp` drivers / Win32 LPT):
/// | Pattern                | Platform      |
/// |------------------------|---------------|
/// | `lpt`, `lpt0`…`lpt9`  | All (alias)   |
/// | `lp0`…`lp9`           | All (alias)   |
/// | `/dev/lp0`…`/dev/lpN` | Linux         |
/// | `\\.\LPT1`…`\\.\LPT9` | Windows       |
///
/// **USB printer class** (`bInterfaceClass = 0x07`, `usblp` driver):
/// | Pattern                   | Platform      |
/// |---------------------------|---------------|
/// | `usblp0`…`usblp15`        | Linux (alias) |
/// | `/dev/usb/lp0`…`lpN`      | Linux         |
/// | `/dev/usblp0`…`usblpN`    | Linux (older) |
/// | `usblpt:0`…`usblpt:N`     | Android       |
bool isLptPort(String name) {
  final lower = name.toLowerCase();
  // Short / alias names for a real parallel port: lpt, lpt0, lp0 …
  if (RegExp(r'^lpt?\d*$').hasMatch(lower)) return true;
  // Short / alias name for a USB printer class device: usblp0 …
  if (RegExp(r'^usblp\d+$').hasMatch(lower)) return true;
  // Linux character device paths (parallel and USB printer)
  if (RegExp(r'^/dev/lp\d+$').hasMatch(lower)) return true;
  if (_kUsbPrinterPath.hasMatch(lower)) return true;
  // Windows UNC device path (\\.\LPT1)
  if (lower.startsWith('\\\\.\\lpt')) return true;
  // Android USB index notation
  if (lower.startsWith('usblpt:')) return true;
  return false;
}

/// Converts a convenience port name to the canonical device path for the
/// current operating system.
///
/// | Input     | Linux output    | Windows output |
/// |-----------|-----------------|----------------|
/// | `lpt0`    | `/dev/lp0`      | `\\.\LPT1`     |
/// | `lp1`     | `/dev/lp1`      | `\\.\LPT1`     |
/// | `lpt2`    | `/dev/lp2`      | `\\.\LPT2`     |
/// | `usblp0`  | `/dev/usb/lp0`  | (unsupported)  |
///
/// Paths that already use the full OS-specific form are returned unchanged.
///
/// **Note:** Windows LPT ports are 1-based (`LPT1`…`LPT9`).  `lpt0` is
/// treated as an alias for `LPT1` on Windows.  USB printers on Windows are
/// reached through the print spooler rather than a device file, so `usblpN`
/// has no Windows equivalent and resolves to a path that fails to open with a
/// descriptive error.
String lptToDevicePath(String name) {
  final lower = name.toLowerCase();

  // USB printer class device (Linux `usblp` driver).
  final usbMatch = RegExp(r'^usblp(\d+)$').firstMatch(lower);
  if (usbMatch != null) {
    final num = int.parse(usbMatch.group(1)!);
    if (Platform.isWindows) return '\\\\.\\USBLP$num';
    // Older udev rules use /dev/usblpN instead of /dev/usb/lpN.
    if (File('/dev/usblp$num').existsSync()) return '/dev/usblp$num';
    return '/dev/usb/lp$num';
  }

  // Real parallel port: `lpt`, `lpt0`, `lp0` …
  final shortMatch = RegExp(r'^lpt?(\d*)$').firstMatch(lower);
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

/// [SerialPort]-compatible wrapper for **desktop** parallel (LPT) and USB
/// printer class ports.
///
/// | Platform | Device path            | Notes                                |
/// |----------|------------------------|--------------------------------------|
/// | Linux    | `/dev/lp0`…`/dev/lpN`  | Parallel port, `parport`+`lp` drivers|
/// | Linux    | `/dev/usb/lp0`…`lpN`   | USB printer class, `usblp` driver    |
/// | Linux    | `/dev/usblp0`…`usblpN` | Same, older udev naming              |
/// | Windows  | `\\.\LPT1`…`\\.\LPT9` | Win32 device file                    |
/// | macOS    | —                      | Not natively supported               |
///
/// The two Linux families are independent: `/dev/lp0` and `/dev/usb/lp0` can
/// be two different printers on the same machine.  USB receipt printers such
/// as the Epson TM-T20 always show up as `/dev/usb/lp*`, never as `/dev/lp*`.
///
/// Parallel ports are write-only, and so are unidirectional USB printer
/// interfaces; on those [read] returns an empty [Uint8List].  Bidirectional
/// USB printers do answer status queries — see [read].  Configuration (baud
/// rate, parity etc.) is not applicable and is silently accepted but ignored.
class SerialPortLpt implements SerialPort {
  final String _devicePath;
  RandomAccessFile? _file;
  bool _isOpen = false;
  int _mode = SerialPortMode.write;
  Future<Uint8List>? _pendingRead;
  SerialPortConfig? _config;
  String? _cachedDeviceId;

  /// Stores the most recent error.  Exposed via [SerialPort.lastError].
  static SerialPortError? _lastError;

  SerialPortLpt(String name) : _devicePath = lptToDevicePath(name);

  /// @internal – not meaningful for LPT; kept for interface compatibility.
  SerialPortLpt.fromAddress(int address)
    : _devicePath =
          Platform.isWindows
              ? '\\\\.\\LPT${(address & 0xff) + 1}'
              : '/dev/lp${address & 0xff}';

  // ── Static helpers ─────────────────────────────────────────────────────────

  /// Lists all parallel and USB printer ports that appear present on the
  /// system.
  ///
  /// * **Linux** – enumerates `/dev/usb/lp*` (USB printer class, `usblp`),
  ///   `/dev/usblp*` (older udev naming) and `/dev/lp*` (parallel port).
  /// * **Windows** – attempts to briefly open `\\.\LPT1`…`\\.\LPT9`.
  ///
  /// A port being listed means the device node exists, not that the current
  /// user may open it: `/dev/usb/lp*` is usually `root:lp 0660`, and the
  /// `usblp` driver only allows a single opener at a time (CUPS may hold it).
  static Future<List<String>> get availablePorts async {
    if (Platform.isLinux) {
      return _linuxPorts();
    } else if (Platform.isWindows) {
      return _windowsPorts();
    }
    return [];
  }

  /// Enumerates the printer device nodes present under `/dev`.
  ///
  /// Directory listing is used rather than probing a fixed set of names: the
  /// `usblp` driver supports 16 minors, and both the number and the naming
  /// (`/dev/usb/lpN` vs `/dev/usblpN`) depend on the udev rules in use.
  ///
  /// **Note:** `Directory.list()` reports character devices as [File] entries,
  /// so the nodes do show up.  `FileSystemEntity.type()` must *not* be used
  /// here - it reports [FileSystemEntityType.notFound] for character devices.
  static Future<List<String>> _linuxPorts() async {
    final result = <String>[
      ...await _scanDir('/dev/usb', RegExp(r'^lp(\d+)$')),
      ...await _scanDir('/dev', RegExp(r'^(?:usb)?lp(\d+)$')),
    ];
    // Natural order: lp2 before lp10.
    final split = RegExp(r'^(.*?)(\d+)$');
    result.sort((a, b) {
      final ma = split.firstMatch(a)!;
      final mb = split.firstMatch(b)!;
      final byPrefix = ma.group(1)!.compareTo(mb.group(1)!);
      if (byPrefix != 0) return byPrefix;
      return int.parse(ma.group(2)!).compareTo(int.parse(mb.group(2)!));
    });
    return result;
  }

  static Future<List<String>> _scanDir(String path, RegExp pattern) async {
    final result = <String>[];
    try {
      final dir = Directory(path);
      if (!await dir.exists()) return result;
      await for (final entity in dir.list(followLinks: false)) {
        final name = entity.path.split('/').last;
        if (pattern.hasMatch(name)) result.add(entity.path);
      }
    } catch (e) {
      // /dev or /dev/usb not readable (sandboxed snap/flatpak, container).
      _log('Could not scan $path: $e');
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

  /// @internal - returns and clears the last LPT error.
  ///
  /// [SerialPort.lastError] prefers the LPT error over the libserialport one,
  /// so it must be consumed; otherwise a stale LPT failure would mask every
  /// subsequent serial port error for the rest of the process lifetime.
  static SerialPortError? consumeLastError() {
    final error = _lastError;
    _lastError = null;
    return error;
  }

  // ── SerialPort interface ───────────────────────────────────────────────────

  @override
  int get address => _devicePath.hashCode;

  @override
  String? get name => _devicePath;

  /// Whether this port is a USB printer class device rather than a real
  /// IEEE-1284 parallel port.
  bool get _isUsbPrinter => _kUsbPrinterPath.hasMatch(_devicePath);

  @override
  String? get description {
    if (!_isUsbPrinter) return 'Parallel port ($_devicePath)';
    final model = _deviceIdField('MDL') ?? _deviceIdField('MODEL');
    final mfg = _deviceIdField('MFG') ?? _deviceIdField('MANUFACTURER');
    if (model == null) return 'USB printer ($_devicePath)';
    return '${mfg == null ? '' : '$mfg '}$model ($_devicePath)';
  }

  @override
  int get transport =>
      _isUsbPrinter ? SerialPortTransport.usb : SerialPortTransport.native;

  /// Reads the IEEE-1284 device ID string exported by the `usblp` driver.
  ///
  /// Example: `MFG:EPSON;CMD:ESCPOS;MDL:TM-T20;CLS:PRINTER;`
  String? get _ieee1284Id {
    if (_cachedDeviceId != null) return _cachedDeviceId;
    final match = _kUsbPrinterPath.firstMatch(_devicePath);
    if (match == null) return null;
    final minor = match.group(2)!;
    for (final path in [
      '/sys/class/usbmisc/lp$minor/device/ieee1284_id',
      '/sys/class/printer/lp$minor/device/ieee1284_id',
    ]) {
      try {
        final file = File(path);
        if (file.existsSync()) {
          return _cachedDeviceId = file.readAsStringSync().trim();
        }
      } catch (_) {
        // sysfs not available or not readable; fall through.
      }
    }
    return null;
  }

  String? _deviceIdField(String key) {
    final id = _ieee1284Id;
    if (id == null) return null;
    for (final field in id.split(';')) {
      final sep = field.indexOf(':');
      if (sep < 0) continue;
      if (field.substring(0, sep).trim().toUpperCase() == key) {
        final value = field.substring(sep + 1).trim();
        if (value.isNotEmpty) return value;
      }
    }
    return null;
  }

  @override
  int? get busNumber => null;
  @override
  int? get deviceNumber => null;
  @override
  int? get vendorId => null;
  @override
  int? get productId => null;
  @override
  String? get manufacturer =>
      _deviceIdField('MFG') ?? _deviceIdField('MANUFACTURER');
  @override
  String? get productName => _deviceIdField('MDL') ?? _deviceIdField('MODEL');
  @override
  String? get serialNumber => _deviceIdField('SN') ?? _deviceIdField('SERN');
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
      if (Platform.isLinux) {
        if (!await file.exists()) {
          _log('Device file not found: $_devicePath');
          _lastError = SerialPortError(
            'Printer device not found: $_devicePath  '
            '(check that the kernel module is loaded: '
            'lsmod | grep -E "^lp|usblp")',
            -1,
          );
          return false;
        }
        // A character device stats as `notFound` while `exists()` is true.
        // Anything reported as a regular file is a leftover created by a
        // previous O_CREAT open and would silently swallow the print data.
        if ((await file.stat()).type == FileSystemEntityType.file) {
          _log('$_devicePath is a regular file, not a device node');
          _lastError = SerialPortError(
            '$_devicePath is a regular file, not a character device. '
            'Remove it and re-plug the printer so udev can recreate the node.',
            -1,
          );
          return false;
        }
      }

      _log('Opening $_devicePath (mode $mode)');
      _file = await file.open(mode: _fileMode(mode));
      _mode = mode;
      _isOpen = true;
      _log('Opened $_devicePath successfully (fd is valid)');
      return true;
    } on FileSystemException catch (e) {
      _log(
        'Failed to open $_devicePath: ${e.message} (OS Error: ${e.osError})',
      );
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

  /// Maps a [SerialPortMode] to the corresponding [FileMode].
  ///
  /// `FileMode.write` is `O_RDWR|O_CREAT|O_TRUNC`, so it requests write access
  /// even for a read-only open and truncates.  Append modes avoid `O_TRUNC`;
  /// `O_CREAT` cannot be avoided in dart:io, hence the device node check in
  /// [open].  Windows keeps the previous behaviour, since its LPT device files
  /// reject the append flags.
  FileMode _fileMode(int mode) {
    if (Platform.isWindows) return FileMode.write;
    switch (mode) {
      case SerialPortMode.read:
        return FileMode.read; // O_RDONLY, no O_CREAT
      case SerialPortMode.readWrite:
        return FileMode.append; // O_RDWR|O_CREAT|O_APPEND
      default:
        return FileMode.writeOnlyAppend; // O_WRONLY|O_CREAT|O_APPEND
    }
  }

  bool get _isReadable => _mode & SerialPortMode.read != 0;
  bool get _isWritable => _mode & SerialPortMode.write != 0;

  /// Provides context-aware hints for common LPT access errors.
  static String _permissionHint(FileSystemException e) {
    final code = e.osError?.errorCode;
    if (code == 13 /* EACCES */ || code == 1 /* EPERM */ ) {
      if (Platform.isLinux) {
        return '\n  Hint: add your user to the lp group:\n'
            '  sudo usermod -a -G lp \$USER && newgrp lp';
      }
    }
    if (code == 16 /* EBUSY */ ) {
      return '\n  Hint: the port is busy (another process has it open). '
          'On Linux the usblp driver allows a single opener - CUPS may be '
          'holding the printer; try: sudo systemctl stop cups';
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
    _pendingRead = null;
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

  /// Writes [bytes] to the printer.
  ///
  /// If `timeout` is greater than 0, the write is aborted after that many
  /// milliseconds.  This matters on Linux: writing to `/dev/usb/lp*` or
  /// `/dev/lp*` blocks indefinitely while the printer is offline or out of
  /// paper, which would otherwise freeze the calling isolate.
  @override
  Future<int> write(Uint8List bytes, {int timeout = -1}) async {
    if (_file == null || !_isOpen) {
      _lastError = SerialPortError('Port is not open', -1);
      return -1;
    }
    if (!_isWritable) {
      _lastError = SerialPortError('Port is not open for writing', -1);
      return -1;
    }
    _lastError = null;
    try {
      _log('Writing ${bytes.length} bytes to $_devicePath');
      // Flush immediately — for character devices like /dev/lp* the kernel
      // may buffer the data until explicitly flushed or the fd is closed.
      var op = _file!.writeFrom(bytes).then((file) => file.flush());
      if (timeout > 0) {
        op = op.timeout(Duration(milliseconds: timeout));
      }
      await op;
      _log('Write and flush completed');
      return bytes.length;
    } on TimeoutException {
      _log('Write to $_devicePath timed out after ${timeout}ms');
      _lastError = SerialPortError(
        'Write timed out after ${timeout}ms: $_devicePath '
        '(printer offline, out of paper or not accepting data?)',
        -1,
      );
      return -1;
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

  /// Reads up to [bytes] bytes from the printer.
  ///
  /// Only works when the port was opened with [openRead] or [openReadWrite]
  /// **and** the device is bidirectional.  Real parallel ports and
  /// unidirectional USB printer interfaces (`bInterfaceProtocol` 1) never
  /// return data; bidirectional ones (protocol 2, e.g. Epson TM-T20) answer
  /// ESC/POS status queries such as `DLE EOT n`.
  ///
  /// `timeout` follows the [SerialPort] convention: negative means
  /// non-blocking (emulated with a short grace period, since dart:io has no
  /// non-blocking read), `0` waits indefinitely, and any other value is a
  /// timeout in milliseconds.  A read that times out stays pending in the
  /// background and its result is delivered to the next [read] call.
  @override
  Future<Uint8List> read(int bytes, {int timeout = -1}) async {
    if (_file == null || !_isOpen) {
      _lastError = SerialPortError('Port is not open', -1);
      return Uint8List(0);
    }
    if (!_isReadable) {
      _log('Read requested on $_devicePath but it is not open for reading');
      return Uint8List(0);
    }
    if (bytes <= 0) return Uint8List(0);

    var pending = _pendingRead;
    if (pending == null) {
      // Errors are absorbed here so that a timed-out read left running in the
      // background never surfaces as an unhandled asynchronous error.
      pending = _file!.read(bytes).catchError((Object e) {
        _log('Read failed on $_devicePath: $e');
        _lastError =
            e is FileSystemException
                ? SerialPortError(
                  '${e.message}: $_devicePath',
                  e.osError?.errorCode ?? -1,
                )
                : SerialPortError(e.toString(), -1);
        return Uint8List(0);
      });
      final current = pending;
      _pendingRead = current;
      current.whenComplete(() {
        if (identical(_pendingRead, current)) _pendingRead = null;
      });
    }

    if (timeout == 0) return await pending;
    final limit =
        timeout < 0
            ? const Duration(milliseconds: 50)
            : Duration(milliseconds: timeout);
    try {
      return await pending.timeout(limit);
    } on TimeoutException {
      return Uint8List(0);
    }
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

/// [SerialPortReader] implementation for LPT and USB printer ports.
///
/// Parallel ports never produce data, so the stream simply stays empty for
/// them.  Bidirectional USB printers opened with [SerialPort.openReadWrite]
/// are polled sequentially: a read is issued, its result (if any) is pushed to
/// the stream, and the next read is issued.
class SerialPortReaderLpt implements SerialPortReader {
  final SerialPortLpt _port;
  final int _timeout;
  StreamController<Uint8List>? __controller;
  bool _reading = false;

  SerialPortReaderLpt(SerialPort port, {int? timeout})
    : _port = port as SerialPortLpt,
      _timeout = timeout ?? 500;

  @override
  SerialPort get port => _port;

  @override
  Stream<Uint8List> get stream => _controller.stream;

  StreamController<Uint8List> get _controller {
    return __controller ??= StreamController<Uint8List>(
      onListen: _startRead,
      onCancel: _cancelRead,
      onPause: _cancelRead,
      onResume: _startRead,
    );
  }

  void _startRead() {
    if (_reading) return;
    _reading = true;
    _poll();
  }

  void _cancelRead() => _reading = false;

  Future<void> _poll() async {
    while (_reading) {
      if (!_port.isOpen) break;
      final data = await _port.read(_kReadChunkSize, timeout: _timeout);
      if (!_reading) break;
      if (data.isNotEmpty) {
        _controller.add(data);
      } else {
        final error = SerialPortLpt.lastError;
        if (error != null) {
          _controller.addError(error);
          break;
        }
      }
    }
  }

  @override
  void close() {
    _cancelRead();
    __controller?.close();
    __controller = null;
  }
}

/// Chunk size used when polling a bidirectional printer for status bytes.
const int _kReadChunkSize = 64;

extension SerialPortLptReader on SerialPortLpt {
  /// Provides access to an LPT-compatible reader.
  SerialPortReader get reader => SerialPortReaderLpt(this);
}
