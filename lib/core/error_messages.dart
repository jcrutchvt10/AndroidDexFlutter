/// Two-tier messaging, matching the Android-Dex error contract:
///
/// * **Dev log** — raw process output, stack traces, exit codes, file paths.
/// * **User message** — plain English, actionable, no technical jargon.
///
/// Every failure raised by the boot/reconnect pipeline is therefore an
/// [AndroidDexError] whose [AndroidDexError.userMessage] is safe to render on
/// the boot screen verbatim, while [AndroidDexError.devDetail] carries the
/// technical payload for [devLog].
class AndroidDexError implements Exception {
  const AndroidDexError(this.userMessage, {this.devDetail});

  final String userMessage;
  final String? devDetail;

  @override
  String toString() => userMessage;
}

/// A failure the user can resolve by choosing a different ADB target. These
/// drive the "Open ADB Manager" recovery button on the boot screen.
class ConnectionFailure extends AndroidDexError {
  const ConnectionFailure(super.userMessage, {super.devDetail});
}

// --- AdbProvider ---------------------------------------------------------

const kAdbRuntimeMissing =
    'ADB runtime not found. Please reinstall the application.';
const kCompanionApkMissing =
    'Companion APK is missing from the installation folder. Please reinstall.';
const kServiceModuleMissing =
    'Service module not found in the installation folder. Please reinstall.';
const kAdbServerFailed =
    'ADB server failed to start. Close any other ADB instances and retry.';
const kAdbCommandTimedOut =
    'The device took too long to answer. Check the connection and retry.';
const kAdbCommandFailed =
    'Could not talk to the ADB runtime. Reconnect the device and retry.';
const kDeviceConnectFailed =
    'Unable to connect to the device. Verify the IP address or check the USB cable.';
const kNoDeviceSelected = 'No device selected. Connect an Android device';
const kMultipleDevicesFound =
    'More than one Android device is connected. Choose the device to use.';

String kBridgeFailed(int port) =>
    'Network bridge setup failed on port $port. The device may have revoked '
    'ADB permissions.';

String kIpConnectFailed(String address) =>
    'Unable to connect to $address — verify the IP and try again.';

const kIpConnectCrashed =
    'Connection failed — ensure ADB over Wi-Fi is enabled on the device.';
const kIpAddressRequired = 'Enter a valid IP address';

// --- JarManager ----------------------------------------------------------

const kServiceTransferFailed =
    'Could not transfer service to device. Check connection and try again.';
const kServiceInitFailed =
    'Service initialization failed. Ensure the device is connected.';
const kServiceStoppedUnexpectedly =
    'Service process stopped unexpectedly. Will attempt reconnection.';

// --- AppManager ----------------------------------------------------------

const kAppInstallFailed =
    'App installation failed. Check device storage and USB permissions.';
const kServiceLaunchFailed =
    'Failed to launch Android service. Try restarting the device.';
const kJarHandshakeTimeout =
    'Background service timed out. The device may be busy or unreachable.';
const kApkHandshakeTimeout =
    'Companion app timed out. Ensure it is installed and running on the device.';

// --- ReconnectionManager -------------------------------------------------

const kDeviceDisconnected =
    'Device disconnected. Check your USB cable or Wi-Fi connection.';
const kReconnectFailedUnexpectedly =
    'Reconnection failed unexpectedly. Try restarting the application.';

// --- Host bundle ---------------------------------------------------------

const kBundleMissing =
    'The Android DEX host bundle is missing. Reinstall the application.';
const kWindowRuntimeMissing =
    'The bundled Android window runtime is missing. Reinstall the application.';
const kWindowServerMissing =
    'The matching Android window server is missing. Reinstall the application.';

/// Messages whose recovery action is reinstalling the app, not fiddling with
/// the device. These must never raise the "Open ADB Manager" affordance —
/// note `kAdbRuntimeMissing` contains the substring "adb" and would otherwise
/// be misclassified by [isConnectionError].
const _reinstallMessages = [
  kBundleMissing,
  kAdbRuntimeMissing,
  kCompanionApkMissing,
  kServiceModuleMissing,
  kWindowRuntimeMissing,
  kWindowServerMissing,
];

bool isReinstallError(String message) => _reinstallMessages.contains(message);

/// Heuristic used to decide whether an error is worth offering the device
/// picker for. A reinstall-style failure would not benefit from it.
bool isConnectionError(String message) {
  if (isReinstallError(message)) return false;
  final lower = message.toLowerCase();
  return lower.contains('connect') ||
      lower.contains('device') ||
      lower.contains('adb') ||
      lower.contains('reverse') ||
      lower.contains('network') ||
      lower.contains('bridge') ||
      lower.contains('refused') ||
      lower.contains('timeout') ||
      lower.contains('timed out') ||
      lower.contains('unreachable') ||
      lower.contains('disconnected');
}

/// Normalises any thrown object into user-facing text. Raw exception dumps are
/// never forwarded; technical detail is routed to the dev log instead.
///
/// Known wrapper prefixes (`Exception:`, `Bad state:`, `FormatException:`)
/// are stripped so second-hand stderr text reads like a sentence.
String userMessageFor(Object error) {
  if (error is AndroidDexError) return error.userMessage;
  return _stripWrappers(error.toString());
}

String _stripWrappers(String text) {
  const wrappers = [
    'Exception: ',
    'Bad state: ',
    'FormatException: ',
    'StateError: ',
  ];
  for (final wrapper in wrappers) {
    if (text.startsWith(wrapper)) {
      return _stripWrappers(text.substring(wrapper.length));
    }
  }
  return text;
}
