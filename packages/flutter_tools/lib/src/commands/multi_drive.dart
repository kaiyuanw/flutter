import 'dart:async';
import 'dart:convert' show JSON;
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

    argParser.addOption(
      'specs',
      defaultsTo: null,
      allowMultiple: false,
      help:
        'Config file that specifies the devices, apps and debug-ports for testing.'
    );

    // argParser.addOption(
    //   'debug-ports',
    //   defaultsTo: kDefaultMultiDrivePort,
    //   allowMultiple: true,
    //   splitCommas: true,
    //   help: 'Listen to a list of ports for a debug connection.'
    // );
  }

  @override
  final String name = 'multi-drive';

  @override
  final String description = 'Runs Flutter Multi-Device Driver tests for the current project.';

  @override
  final List<String> aliases = <String>['multi-driver'];

  List<Device> _devices;
  List<Device> get devices => _devices;

  dynamic specs;

  // List<int> get debugPorts =>
  //   argResults['debug-ports']
  //   .split(',')
  //   .foreach((String port) => int.parse(port));

  @override
  Future<int> runInProject() async {
    String specsPath = argResults['specs'];
    this.specs = await _loadSpecs(specsPath);
    print(specs);

    this._devices = await targetDevicesFinder();
    if (devices == null) {
      return 1;
    }

    String testFile = specs['test-path'];

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

  Future<dynamic> _loadSpecs(String specsPath) async {
    // Read specs file into json format
    dynamic spec = JSON.decode(await new io.File(specsPath).readAsString());
    // Get the parent directory of the specs file
    String rootPath = new io.File(specsPath).parent.absolute.path;
    // Normalize the 'test-path' in the specs file
    spec['test-path'] = _normalizePath(rootPath, spec['test-path']);
    // Normalize the 'app-path' in the specs file
    spec['devices'].forEach((String deviceID, Map<String, String> value) {
      value['app-path'] = _normalizePath(rootPath, value['app-path']);
    });
    return spec;
  }

  String _normalizePath(String rootPath, String relativePath) {
    return path.normalize(path.join(rootPath, relativePath));
  }
}

/// Finds a device to test on. May launch a simulator, if necessary.
typedef Future<List<Device>> TargetDevicesFinder();
TargetDevicesFinder targetDevicesFinder = findTargetDevices;
void restoreTargetDevicesFinder() {
  targetDevicesFinder = findTargetDevices;
}

Future<List<Device>> findTargetDevices() async {
  // Should not specify a single device id
  /*
  if (deviceManager.hasSpecifiedDeviceId) {
    return deviceManager.getDeviceById(deviceManager.specifiedDeviceId);
  }
  */

  List<Device> devices = await deviceManager.getAllConnectedDevices();

  if (os.isMacOS || os.isLinux) {
    // On MacOS or Linux, we grab the all connected device we can find.
    if (devices.isEmpty) {
      printError('No devices found.');
      return null;
    } else {
      print(
        'Found connected device${ devices.length == 1 ? '' : 's' }:\n'
        '<${devices.join(",")}>'
      );
      return devices;
    }
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
  // command.specs['devices']['HT4CWJT03204']['app-path']
  String mainPath = findMainDartFile(command.target);
  if (await fs.type(mainPath) != FileSystemEntityType.FILE) {
    printError('Tried to run $mainPath, but that file does not exist.');
    return 1;
  }

  // TODO(devoncarew): We should remove the need to special case here.
  if (command.devices is AndroidDevice) {
    printTrace('Building an APK.');
    int result = await build_apk.buildApk(
      command.devices[0].platform,
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
      .getPackageForPlatform(command.devices[0].platform);
  if (command.devices[0].isAppInstalled(package))
    command.devices[0].uninstallApp(package);
  command.devices[0].installApp(package);

  Map<String, dynamic> platformArgs = <String, dynamic>{};
  if (command.traceStartup)
    platformArgs['trace-startup'] = command.traceStartup;

  printTrace('Starting application.');
  LaunchResult result = await command.devices[0].startApp(
    package,
    command.getBuildMode(),
    mainPath: mainPath,
    route: command.route,
    debuggingOptions: new DebuggingOptions.enabled(
      command.getBuildMode(),
      startPaused: true,
      observatoryPort: 0//command.debugPorts[0]
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
  ApplicationPackage package = command.applicationPackages.getPackageForPlatform(command.devices[0].platform);
  bool stopped = await command.devices[0].stopApp(package);
  return stopped ? 0 : 1;
}
