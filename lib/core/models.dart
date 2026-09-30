/// Shared desktop model types.
///
/// These live outside `AndroidCore` so the window manager and the UI can use
/// them without importing the state store back into itself.
library;

/// One installed Android application, as reported by `get_all_apps`.
class AndroidAppInfo {
  const AndroidAppInfo({
    required this.name,
    required this.packageName,
    required this.versionName,
    required this.iconBase64,
  });

  factory AndroidAppInfo.fromJson(Map<String, dynamic> json) => AndroidAppInfo(
    name: json['app_name'] as String? ?? json['package_name'] as String? ?? '',
    packageName: json['package_name'] as String? ?? '',
    versionName: json['version_name'] as String? ?? '',
    iconBase64: json['icon_base64'] as String? ?? '',
  );

  final String name;
  final String packageName;
  final String versionName;
  final String iconBase64;

  bool get hasIcon => iconBase64.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is AndroidAppInfo && other.packageName == packageName;

  @override
  int get hashCode => packageName.hashCode;
}

/// A running Android application window backed by its own scrcpy process.
class DesktopAppWindow {
  const DesktopAppWindow({
    required this.app,
    required this.startedAt,
    required this.processId,
  });

  final AndroidAppInfo app;
  final DateTime startedAt;
  final int processId;

  String get packageName => app.packageName;
}
