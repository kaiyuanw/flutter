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
import '../runner/flutter_command.dart';
import 'build_apk.dart' as build_apk;
import 'run.dart';

// TODO(kaiyuanw): Add tests for this file
class MultiDriveCommand extends FlutterCommand {
  MultiDriveCommand() {
    addBuildModeFlags(defaultToRelease: false);

    argParser.addFlag('trace-startup',
        negatable: true,
        defaultsTo: false,
        help: 'Start tracing during startup.');

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

    // Add --specs option to load the specs file that specifies test path,
    // device ids, application paths and debug ports
    argParser.addOption(
      'specs',
      defaultsTo: null,
      allowMultiple: false,
      help:
        'Path to the config file that specifies the devices, '
        'apps and debug-ports for testing.'
    );
  }

  bool get traceStartup => argResults['trace-startup'];

  // TODO(kaiyuanw): Need to read 'route' from the specs file
  String get route => null;//argResults['route'];

  @override
  final String name = 'multi-drive';

  @override
  final String description = 'Run Flutter Multi-Device Driver tests for the current project.';

  @override
  final List<String> aliases = <String>['multi-driver'];

  List<Device> _devices;

  List<Device> get devices => _devices;

  dynamic specs;

  @override
  Future<int> runInProject() async {
    String specsPath = argResults['specs'];
    if(specsPath == null) {
      print('--specs=$specsPath, you must pass a non-null path to the specs argument.');
      return 1;
    }
    this.specs = await loadSpecs(specsPath);
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
      // printStatus('Starting application: ${argResults["target"]}');

      if (getBuildMode() == BuildMode.release) {
        // This is because we need VM service to be able to drive the app.
        printError(
          'Flutter Multi-Device Driver does not support running in release mode.\n'
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
          await allAppsStopper(this);
        } catch(error, stackTrace) {
          // TODO(yjbanov): remove this guard when this bug is fixed: https://github.com/dart-lang/sdk/issues/25862
          printTrace('Could not stop application: $error\n$stackTrace');
        }
      } else {
        printStatus('Leaving the application running.');
      }
    }
  }
}

Future<dynamic> loadSpecs(String specsPath) async {
  try {
    // Read specs file into json format
    dynamic newSpecs = JSON.decode(await new io.File(specsPath).readAsString());
    // Get the parent directory of the specs file
    String rootPath = new io.File(specsPath).parent.absolute.path;
    // Normalize the 'test-path' in the specs file
    newSpecs['test-path'] = normalizePath(rootPath, newSpecs['test-path']);
    // Normalize the 'app-path' in the specs file
    newSpecs['devices'].forEach((String name, Map<String, String> map) {
      map['app-path'] = normalizePath(rootPath, map['app-path']);
    });
    return newSpecs;
  } on io.FileSystemException {
    printError('File $specsPath does not exist.');
    io.exit(1);
  } on FormatException {
    printError('File $specsPath is not in JSON format.');
    io.exit(1);
  } catch (e) {
    print('Unknown Exception details:\n $e');
    io.exit(1);
  }
}

String normalizePath(String rootPath, String relativePath) {
  return path.normalize(path.join(rootPath, relativePath));
}

/// Finds a device to test on. May launch a simulator, if necessary.
typedef Future<List<Device>> TargetDevicesFinder();
TargetDevicesFinder targetDevicesFinder = findTargetDevices;
void restoreTargetDevicesFinder() {
  targetDevicesFinder = findTargetDevices;
}

Future<List<Device>> findTargetDevices() async {
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

// Device findDevice(List<Device> devices, String deviceID) {
//   for(Device device in devices) {
//     if(device.id == deviceID) return device;
//   }
//   return null;
// }

/// Check if the given port is available.  If the port can be connected to,
/// then it is in use, otherwise it is available.
Future<bool> isAvailable(int port) async {
  Uri uri = Uri.parse('http://localhost:$port');
  if (uri.scheme == 'http') uri = uri.replace(scheme: 'ws', path: '/ws');
  bool isAvailable = false;
  io.WebSocket ws;
  try {
    ws = await io.WebSocket.connect(uri.toString());
  } catch(e) {
    isAvailable = true;
  } finally {
    if(ws != null) {
      ws.close();
    }
  }
  return isAvailable;
}

// Record ports that have already been assigned
Set<int> portsAssigned = new Set<int>();
// Keep a counter that refer to the first potential available port
// after kDefaultDebugPortBase
int potentialAvailablePort = kDefaultDebugPortBase;
// The biggest port that we try
int portUpperBound = kDefaultDebugPortBase + kDefaultPortRange;

Future<String> findNextAvailablePort() async {
  while(!await isAvailable(potentialAvailablePort)
        ||
        portsAssigned.contains(potentialAvailablePort)) {
    potentialAvailablePort++;
  }
  int resultPort = potentialAvailablePort++;
  if(resultPort > portUpperBound) {
    printError('No available port found in range '
               '$kDefaultDebugPortBase to $portUpperBound');
    io.exit(1);
  }
  portsAssigned.add(resultPort);
  return '$resultPort';
}

// Future<String> findAvailablePort(int port) async {
//   if(await isAvailable(port) && !portsAssigned.contains(port)) {
//     portsAssigned.add(port);
//     return '$port';
//   } else {
//     return await findNextAvailablePort();
//   }
// }

Future<List<DeviceSpecs>> constructAllDeviceSpecs(dynamic allSpecs) async {
  List<DeviceSpecs> devicesSpecs = <DeviceSpecs>[];
  for(String name in allSpecs.keys) {
    Map<String, String> specs = allSpecs[name];
    // if(specs.containsKey('debug-port')) {
    //   int debugPort = int.parse(specs['debug-port']);
    //   specs['debug-port'] = await findAvailablePort(debugPort);
    // } else {
    //   specs['debug-port'] = await findNextAvailablePort();
    // }
    // print(specs['debug-port']);
    specs['debug-port'] = await findNextAvailablePort();
    devicesSpecs.add(
      new DeviceSpecs(
        nickName: name,
        deviceID: specs['device-id'],
        deviceModelName: specs['model-name'],
        appPath: specs['app-path'],
        debugPort: specs['debug-port']
      )
    );
  }
  return devicesSpecs;
}

Map<DeviceSpecs, Set<Device>> findIndividualMatches(
  List<DeviceSpecs> devicesSpecs,
  List<Device> devices) {
  Map<DeviceSpecs, Set<Device>> individualMatches
    = new Map<DeviceSpecs, Set<Device>>();
  for(DeviceSpecs deviceSpecs in devicesSpecs) {
    Set<Device> matchedDevices = new Set<Device>();
    for(Device device in devices) {
      if(deviceSpecs.matches(device))
        matchedDevices.add(device);
    }
    individualMatches[deviceSpecs] = matchedDevices;
  }
  return individualMatches;
}

bool findAllMatches(
  int order,
  List<DeviceSpecs> devicesSpecs,
  Map<DeviceSpecs, Set<Device>> individualMatches,
  Set<Device> visited,
  Map<DeviceSpecs, Device> anyMatch
) {
  if(order == devicesSpecs.length) return true;
  DeviceSpecs deviceSpecs = devicesSpecs[order];
  Set<Device> matchedDevices = individualMatches[deviceSpecs];
  for(Device candidate in matchedDevices) {
    if(visited.add(candidate)) {
      anyMatch[deviceSpecs] = candidate;
      if(findAllMatches(order + 1, devicesSpecs, individualMatches,
                        visited, anyMatch))
        return true;
      else {
        visited.remove(candidate);
        anyMatch.remove(deviceSpecs);
      }
    }
  }
  return false;
}

Future<Null> storeMatches(Map<DeviceSpecs, Device> anyMatch) async {
  Map<String, dynamic> matchesData = new Map<String, dynamic>();
  anyMatch.forEach((DeviceSpecs specs, Device device) {
    Map<String, String> idAndPort = new Map<String, String>();
    idAndPort['device-id'] = device.id;
    idAndPort['debug-port'] = specs.debugPort;
    matchesData[specs.nickName] = idAndPort;
  });
  io.Directory systemTempDir = io.Directory.systemTemp;
  io.File tempFile = new io.File('${systemTempDir.path}/$kMultiDriveSpecsName');
  if(await tempFile.exists())
    await tempFile.delete();
  io.File file = await tempFile.create();
  await file.writeAsString(JSON.encode(matchesData));
}

Future<int> startMultiDeviceApps(MultiDriveCommand command) async {
  // Load all device ids
  dynamic allSpecs = command.specs['devices'];
  // Try to install and start apps in parallel
  List<Future<LaunchResult>> installAndStartAppFunctions
    = <Future<LaunchResult>>[];
  // Build all device specs from JSON specs map
  List<DeviceSpecs> allDeviceSpecs = await constructAllDeviceSpecs(allSpecs);
  // Find all devices that matches each device specs
  Map<DeviceSpecs, Set<Device>> individualMatches
    = findIndividualMatches(allDeviceSpecs, command.devices);
  // Given a device specs, find a single device that satisfies the specs.
  // Make sure each specs maps to a device if possible, otherwise complain
  Map<DeviceSpecs, Device> anyMatch = new Map<DeviceSpecs, Device>();
  if(!findAllMatches(0, allDeviceSpecs, individualMatches,
                     new Set<Device>(), anyMatch)) {
    printError('No combination of devices meets the specs file.');
    io.exit(0);
  }
  // Store such specs to device mapping to a temporary file for testing
  await storeMatches(anyMatch);
  // Iterate through device ids to get devices
  for(DeviceSpecs deviceSpecs in allDeviceSpecs) {
    // Find the application path that contains a main function
    String mainPath = findMainDartFile(deviceSpecs.appPath);
    // Complain if the application path does not exist
    if (await fs.type(mainPath) != FileSystemEntityType.FILE) {
      printError('Tried to run $mainPath, but that file does not exist.');
      return 1;
    }
    // Device device = findDevice(command.devices, deviceID);
    Device device = anyMatch[deviceSpecs];
    // TODO(devoncarew): We should remove the need to special case here.
    if (device is AndroidDevice) {
      printTrace('Building an APK.');
      int result = await build_apk.buildApk(
        device.platform,
        target: deviceSpecs.appPath, //command.target,
        buildMode: command.getBuildMode()
      );

      if (result != 0)
        return result;
    }

    printTrace('Stopping previously running application, if any.');
    // TODO(kaiyuanw): Need to support totally separate applications
    await appStopper(command.applicationPackages, device);

    installAndStartAppFunctions.add(
      makeInstallAndStartApp(command, device, mainPath, deviceSpecs.debugPort)
    );
  }
  // Install and start apps in parallel
  // TODO(kaiyuanw): Modify internal synchronous calls to asynchronous calls
  Future.wait(installAndStartAppFunctions)
        .then((List<LaunchResult> results) {
          for(LaunchResult result in results) {
            if(!result.started) return 2;
          }
        });
  return 0;
}

class DeviceSpecs {
  DeviceSpecs(
    {
      this.nickName,
      this.deviceID,
      this.deviceModelName,
      this.appPath,
      this.debugPort
    }
  );

  final String nickName;
  final String deviceID;
  final String deviceModelName;
  final String appPath;
  final String debugPort;

  bool matches(Device device) {
    if(deviceID == device.id) {
      return deviceModelName == null ? true : deviceModelName == device.name;
    } else {
      return deviceID == null ?
              (deviceModelName == null ? true : deviceModelName == device.name)
              : false;
    }
  }

  @override
  String toString() => 'Nickname: $nickName, Target ID: $deviceID, '
                       'Target Model Name: $deviceModelName';
}

Future<LaunchResult> makeInstallAndStartApp(
  MultiDriveCommand command,
  Device device,
  String mainPath,
  String debugPort) async {
    printTrace('Installing application package.');
    ApplicationPackage package = command.applicationPackages
        .getPackageForPlatform(device.platform);
    if (device.isAppInstalled(package))
      device.uninstallApp(package);
    device.installApp(package);

    Map<String, dynamic> platformArgs = <String, dynamic>{};
    if (command.traceStartup)
      platformArgs['trace-startup'] = command.traceStartup;

    printTrace('Starting application.');
    LaunchResult result = await device.startApp(
      package,
      command.getBuildMode(),
      mainPath: mainPath,
      route: command.route,
      debuggingOptions: new DebuggingOptions.enabled(
        command.getBuildMode(),
        startPaused: true,
        observatoryPort: int.parse(debugPort)
      ),
      platformArgs: platformArgs
    );
    return result;
}

/// Runs driver tests.
typedef Future<int> TestRunner(List<String> testArgs);
TestRunner testRunner = runTests;
void restoreMultiDeviceTestRunner() {
  testRunner = runTests;
}

Future<int> runTests(List<String> testArgs) async {
  printTrace('Running driver tests.');
  List<String> args = testArgs.toList()..add('-rexpanded');
  await executable.main(args);
  return io.exitCode;
}


/// Stops the application.
typedef Future<int> AppStopper(
  ApplicationPackageStore packageStore,
  Device device);
AppStopper appStopper = stopApp;
void restoreAppStopper() {
  appStopper = stopApp;
}

Future<int> stopApp(
  ApplicationPackageStore packageStore,
  Device device) async {
  printTrace('Stopping application.');
  ApplicationPackage package = packageStore.getPackageForPlatform(device.platform);
  bool stopped = await device.stopApp(package);
  return stopped ? 0 : 1;
}

typedef Future<int> AllAppsStopper(MultiDriveCommand command);
AllAppsStopper allAppsStopper = stopAllApps;
void restoreAllAppsStopper() {
  allAppsStopper = stopAllApps;
}

Future<int> stopAllApps(MultiDriveCommand command) async {
  printTrace('Stopping all applications');
  int result = 0;
  for(Device device in command.devices) {
    ApplicationPackage package = command.applicationPackages
                                        .getPackageForPlatform(device.platform);
    bool stopped = await device.stopApp(package);
    result += stopped ? 0 : 1;
  }
  return result == 0 ? 0 : 1;
}
