import 'dart:async';
import 'dart:io' as io;

import 'package:path/path.dart' as path;
import 'package:test/src/executable.dart' as executable; // ignore: implementation_imports

import '../android/android_device.dart' show AndroidDevice;
import '../application_package.dart';
import '../base/file_system.dart';
import '../base/common.dart';
import '../base/logger.dart';
import '../base/os.dart';
import '../base/process.dart';
import '../build_info.dart';
import '../dart/sdk.dart';
import '../device.dart';
import '../globals.dart';
import '../ios/simulators.dart' show SimControl, IOSSimulatorUtils;
import '../run.dart';
import 'build_apk.dart' as build_apk;
import 'run.dart';

class MultiDriveCommand extends RunCommandBase {
  MultiDriveCommand() {
    argParser.addFlag(
      'keep-app-running',
      negatable: true,
      defaultsTo: false,
      help:
        'Will keep the Flutter application running when done testing. By '
        'default Flutter Driver stops the application after tests are finished.'
    );

    argParser.addFlag(
      'use-existing-app',
      negatable: true,
      defaultsTo: false,
      help:
        'Will not start a new Flutter application but connect to an '
        'already running instance. This will also cause the driver to keep '
        'the application running after tests are done.'
    );

    argParser.addOption('debug-ports',
      defaultsTo: kDefaultMultiDrivePort,
      allowMultiple: true,
      help: 'Listen to a list of ports for a debug connection.'
    );
  }

  @override
  final String name = 'multi-drive';

  @override
  final String description = 'Runs Flutter Multi-Device Driver tests for the current project.';

  @override
  final List<String> aliases = <String>['multi-driver'];

  Device _device;
  Device get device => _device;

  List<int> get debugPorts =>
    argResults['debug-ports']
    .split(',')
    .foreach((String port) => int.parse(port));//int.parse(argResults['debug-port']);

  @override
  Future<int> runInProject() async {
    String testFile = _getTestFile();
    if (testFile == null) {
      return 1;
    }

    this._device = await targetDevicesFinder();
    if (device == null) {
      return 1;
    }

    if (await fs.type(testFile) != FileSystemEntityType.FILE) {
      printError('Test file not found: $testFile');
      return 1;
    }

    if (!argResults['use-existing-app']) {
      printStatus('Starting application: ${argResults["target"]}');

      if (getBuildMode() == BuildMode.release) {
        // This is because we need VM service to be able to drive the app.
        printError(
          'Flutter Driver does not support running in release mode.\n'
          '\n'
          'Use --profile mode for testing application performance.\n'
          'Use --debug (default) mode for testing correctness (with assertions).'
        );
        return 1;
      }

      int result = await appsStarter(this);
      if (result != 0) {
        printError('Application failed to start. Will not run test. Quitting.');
        return result;
      }
    } else {
      printStatus('Will connect to already running application instance.');
    }

    // Check for the existance of a `packages/` directory; pub test does not yet
    // support running without symlinks.
    if (!new io.Directory('packages').existsSync()) {
      Status status = logger.startProgress(
        'Missing packages directory; running `pub get` (to work around https://github.com/dart-lang/test/issues/327):'
      );
      await runAsync(<String>[sdkBinaryName('pub'), 'get', '--no-precompile']);
      status.stop(showElapsedTime: true);
    }

    try {
      return await testRunner(<String>[testFile])
        .catchError((dynamic error, dynamic stackTrace) {
          printError('CAUGHT EXCEPTION: $error\n$stackTrace');
          return 1;
        });
    } finally {
      if (!argResults['keep-app-running'] && !argResults['use-existing-app']) {
        printStatus('Stopping application instance.');
        try {
          await appsStopper(this);
        } catch(error, stackTrace) {
          // TODO(yjbanov): remove this guard when this bug is fixed: https://github.com/dart-lang/sdk/issues/25862
          printTrace('Could not stop application: $error\n$stackTrace');
        }
      } else {
        printStatus('Leaving the application running.');
      }
    }
  }

  String _getTestFile() {
    String appFile = path.normalize(target);

    // This command extends `flutter start` and therefore CWD == package dir
    String packageDir = getCurrentDirectory();

    // Make appFile path relative to package directory because we are looking
    // for the corresponding test file relative to it.
    if (!path.isRelative(appFile)) {
      if (!path.isWithin(packageDir, appFile)) {
        printError(
          'Application file $appFile is outside the package directory $packageDir'
        );
        return null;
      }

      appFile = path.relative(appFile, from: packageDir);
    }

    List<String> parts = path.split(appFile);

    if (parts.length < 2) {
      printError(
        'Application file $appFile must reside in one of the sub-directories '
        'of the package structure, not in the root directory.'
      );
      return null;
    }

    // Look for the test file inside `test_driver/` matching the sub-path, e.g.
    // if the application is `lib/foo/bar.dart`, the test file is expected to
    // be `test_driver/foo/bar_test.dart`.
    String pathWithNoExtension = path.withoutExtension(path.joinAll(
      <String>[packageDir, 'test_driver']..addAll(parts.skip(1))));
    return '${pathWithNoExtension}_test${path.extension(appFile)}';
  }
}

/// Finds a device to test on. May launch a simulator, if necessary.
typedef Future<Device> TargetDevicesFinder();
TargetDevicesFinder targetDevicesFinder = findTargetDevices;
void restoreTargetDevicesFinder() {
  targetDevicesFinder = findTargetDevices;
}

Future<Device> findTargetDevices() async {
  if (deviceManager.hasSpecifiedDeviceId) {
    return deviceManager.getDeviceById(deviceManager.specifiedDeviceId);
  }

  List<Device> devices = await deviceManager.getAllConnectedDevices();

  if (os.isMacOS) {
    // On Mac we look for the iOS Simulator. If available, we use that. Then
    // we look for an Android device. If there's one, we use that. Otherwise,
    // we launch a new iOS Simulator.
    Device reusableDevice = devices.firstWhere(
      (Device d) => d.isLocalEmulator,
      orElse: () {
        return devices.firstWhere((Device d) => d is AndroidDevice,
            orElse: () => null);
      }
    );

    if (reusableDevice != null) {
      printStatus('Found connected ${reusableDevice.isLocalEmulator ? "emulator" : "device"} "${reusableDevice.name}"; will reuse it.');
      return reusableDevice;
    }

    // No running emulator found. Attempt to start one.
    printStatus('Starting iOS Simulator, because did not find existing connected devices.');
    bool started = await SimControl.instance.boot();
    if (started) {
      return IOSSimulatorUtils.instance.getAttachedDevices().first;
    } else {
      printError('Failed to start iOS Simulator.');
      return null;
    }
  } else if (os.isLinux) {
    // On Linux, for now, we just grab the first connected device we can find.
    if (devices.isEmpty) {
      printError('No devices found.');
      return null;
    } else if (devices.length > 1) {
      printStatus('Found multiple connected devices:');
      printStatus(devices.map((Device d) => '  - ${d.name}\n').join(''));
    }
    printStatus('Using device ${devices.first.name}.');
    return devices.first;
  } else if (os.isWindows) {
    printError('Windows is not yet supported.');
    return null;
  } else {
    printError('The operating system on this computer is not supported.');
    return null;
  }
}

/// Starts the application on the device given command configuration.
typedef Future<int> MultiDeviceAppsStarter(MultiDriveCommand command);

MultiDeviceAppsStarter appsStarter = startMultiDeviceApps;
void restoreMultiDeviceAppsStarter() {
  appsStarter = startMultiDeviceApps;
}

Future<int> startMultiDeviceApps(MultiDriveCommand command) async {
  String mainPath = findMainDartFile(command.target);
  if (await fs.type(mainPath) != FileSystemEntityType.FILE) {
    printError('Tried to run $mainPath, but that file does not exist.');
    return 1;
  }

  // TODO(devoncarew): We should remove the need to special case here.
  if (command.device is AndroidDevice) {
    printTrace('Building an APK.');
    int result = await build_apk.buildApk(
      command.device.platform,
      target: command.target,
      buildMode: command.getBuildMode()
    );

    if (result != 0)
      return result;
  }

  printTrace('Stopping previously running application, if any.');
  await appsStopper(command);

  printTrace('Installing application package.');
  ApplicationPackage package = command.applicationPackages
      .getPackageForPlatform(command.device.platform);
  if (command.device.isAppInstalled(package))
    command.device.uninstallApp(package);
  command.device.installApp(package);

  Map<String, dynamic> platformArgs = <String, dynamic>{};
  if (command.traceStartup)
    platformArgs['trace-startup'] = command.traceStartup;

  printTrace('Starting application.');
  LaunchResult result = await command.device.startApp(
    package,
    command.getBuildMode(),
    mainPath: mainPath,
    route: command.route,
    debuggingOptions: new DebuggingOptions.enabled(
      command.getBuildMode(),
      startPaused: true,
      observatoryPort: command.debugPorts[0]
    ),
    platformArgs: platformArgs
  );

  return result.started ? 0 : 2;
}

/// Runs driver tests.
typedef Future<int> MultiDeviceTestRunner(List<String> testArgs);
MultiDeviceTestRunner testRunner = runMultiDeviceTests;
void restoreMultiDeviceTestRunner() {
  testRunner = runMultiDeviceTests;
}

Future<int> runMultiDeviceTests(List<String> testArgs) async {
  printTrace('Running driver tests.');
  List<String> args = testArgs.toList()..add('-rexpanded');
  await executable.main(args);
  return io.exitCode;
}


/// Stops the application.
typedef Future<int> MultiDeviceAppsStopper(MultiDriveCommand command);
MultiDeviceAppsStopper appsStopper = stopMultiDeviceApps;
void restoreMultiDeviceAppsStopper() {
  appsStopper = stopMultiDeviceApps;
}

Future<int> stopMultiDeviceApps(MultiDriveCommand command) async {
  printTrace('Stopping application.');
  ApplicationPackage package = command.applicationPackages.getPackageForPlatform(command.device.platform);
  bool stopped = await command.device.stopApp(package);
  return stopped ? 0 : 1;
}
