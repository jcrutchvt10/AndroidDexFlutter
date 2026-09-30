/// The Android-Dex v1.2 wire contract.
///
/// Every value here was **recovered from the bundled artifacts** — the
/// `classes*.dex` string tables inside `host_bundle/AndroidDex.apk` and the
/// command names baked into `host_bundle/androiddex.jar` — rather than inferred
/// from documentation. In particular:
///
/// * Only `ws://127.0.0.1:3699` exists as a URL literal, so the APK channel is
///   a WebSocket while the JAR, media and notification channels are raw
///   newline-delimited sockets.
/// * `media.hello` / `notification.hello` are the connect-back handshakes on
///   ports 3701 / 3700.
/// * Port 8457 is bound locally *by the APK* for JAR command forwarding and
///   must never be reversed.
class DexProtocol {
  DexProtocol._();

  // --- Identity ----------------------------------------------------------
  static const package = 'com.shrey.androiddex';
  static const serviceComponent =
      'com.shrey.androiddex/.init_start_server.ServerStartService';
  static const jarMainClass = 'com.shrey.androiddex.server.Main';
  static const jarRemotePath = '/data/local/tmp/androiddex.jar';

  // --- Ports -------------------------------------------------------------
  static const jarPort = 3698;
  static const apkPort = 3699;
  static const notificationPort = 3700;
  static const mediaPort = 3701;

  /// Bound on the device by the APK itself; reversing it breaks the bridge.
  static const apkLocalBridgePort = 8457;

  static const reversePorts = <int>[
    jarPort,
    apkPort,
    notificationPort,
    mediaPort,
  ];

  // --- Handshakes --------------------------------------------------------
  static const jarHello = 'jar.hello';
  static const apkHello = 'apk.hello';
  static const mediaHello = 'media.hello';
  static const notificationHello = 'notification.hello';

  // --- APK channel commands ---------------------------------------------
  static const apkGetAllApps = 'get_all_apps';
  static const apkPermissionsGet = 'apk.permissions.get';
  static const apkStateGetAll = 'state.get_all';

  // --- JAR channel commands ---------------------------------------------
  // Verified from the androiddex.jar string table: every literal below was
  // recovered from classes.dex (see docs/HOST_ARCHITECTURE.md).
  static const jarStartOnDisplay = 'app.start_on_display';
  static const jarForceStop = 'app.force_stop';
  static const jarVolumeGetAll = 'volume.get_all';
  static const jarVolumeSet = 'volume.set';
  static const jarDisplayPowerSet = 'display.power.set';
  static const jarWifiDetails = 'wifi.get_details';

  /// Clipboard read/set. `clipboard.text` requests the device clipboard,
  /// `clipboard.set` pushes text onto it. Both are present in the JAR string
  /// table, so they are preferred over ADB shell workarounds.
  static const jarClipboardText = 'clipboard.text';
  static const jarClipboardSet = 'clipboard.set';

  /// Generic ADB shell passthrough. Verified in the JAR string table (three
  /// `shell` literals next to a `Runtime.getRuntime().exec` call site), so it
  /// is a legitimate escape hatch for actions the structured commands lack
  /// (input injection, settings put, svc, keyevents).
  static const jarShell = 'shell';

  /// Handshake expected on the given callback port.
  static String handshakeForPort(int port) => switch (port) {
    mediaPort => mediaHello,
    notificationPort => notificationHello,
    _ => '',
  };
}
