# Changes

## [0.4.3] - 2026-08-17

* Linux: reconhecimento de impressoras USB classe printer (`usblp`) —
  `/dev/usb/lp*` e `/dev/usblp*` — separadas das portas paralelas `/dev/lp*`;
* Linux: enumeração por listagem de diretório (antes só `lp0`..`lp3` fixos);
* Novo alias de porta `usblp0`..`usblpN` (USB) ao lado de `lpt0`/`lp0` (paralela);
* `SerialPortLpt.open()` passa a respeitar o modo (read/write/readWrite) e não
  trunca mais o nó de dispositivo; detecta arquivo regular criado por engano;
* `SerialPortLpt.read()` implementado para impressoras bidirecionais (status
  ESC/POS `DLE EOT`); `SerialPortReaderLpt` agora entrega dados;
* `SerialPortLpt.write()` respeita `timeout` (impressora offline não trava mais);
* `description`/`productName`/`manufacturer` vindos do `ieee1284_id` do sysfs;
* `SerialPort.lastError` não fica mais preso num erro LPT antigo.

## [0.4.2] - 2026-03-10

Atualizado Dependências;

## [0.4.0] - 2025-03-19

* Update Dependencies, Update SDK, Add Android Support, Fixed Lints;

## [0.3.0+1] - 2022-08-07

* Update README.md

## [0.3.0] - 2022-08-27

* Upgrade to Dart 2.17 and package:ffi 2.0 (thanks @Dsthdragon)

## [0.2.0+3] - 2021-08-11

* Clarify SerialPortReader documentation (thanks @thepiper)

## [0.2.0+2] - 2021-03-29

* Fix references to flutter_libserialport.

## [0.2.0+1] - 2021-03-28

* Updated references to flutter_libserialport.

## [0.2.0] - 2021-03-27

* The package has been renamed to libserialport.
* Upgraded dependencies.

## [0.1.0] - 2021-03-09

* Upgraded to Dart 2.12.
* Fixed use of empty FFI structs.
* Use `dylib` package for dynamic library loading.

## [0.1.0-nullsafety.1] - 2021-03-08

* Migrated to ffi 1.0.0

## [0.1.0-nullsafety.0] - 2021-01-01

* Migrated to null safety
* Happy New Year!

## [0.0.7] - 2021-01-01

* Fixed product & vendor ID etc. to return null instead of random
  values when the respective libserialport query fails underneath.

## [0.0.6] - 2021-01-01

* Fixed dynamic library lookup caching

## [0.0.5] - 2020-12-17

* Fixed a null pointer dereference in SerialPort.availablePorts
  Thanks @Coimbra1984!

## [0.0.4+1] - 2020-10-02

* Fixed the example snippet in the README

## [0.0.4] - 2020-10-02

* Added a note about flutter_serial_port "sibling" package

## [0.0.3] - 2020-09-27

* Made SerialPortReader report stream errors
* Added SerialPortReader.port getter
* Added SerialPort.isOpen getter
* Fixed SerialPortReader respect stream pause & resume
* Replaced SerialPort.lastErrorXxx with SerialPort.lastError
* Fixed handling of the LIBSERIALPORT_PATH environment variable
* Fixed error handling for errno=0 type of failures

## [0.0.2] - 2020-09-06

* Fixed a null pointer dereference

## [0.0.1+2] - 2020-09-02

* Example: added missing dispose() call to avoid leaks

## [0.0.1+1] - 2020-09-01

* Address pub.dev score

## [0.0.1] - 2020-09-01

* Initial release
