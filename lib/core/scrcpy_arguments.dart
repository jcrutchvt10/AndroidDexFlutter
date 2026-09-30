const double minVideoBitrateMbps = 1.0;
const double maxVideoBitrateMbps = 32.0;

/// Builds scrcpy's video bitrate option from the user-facing Mbps setting.
String scrcpyVideoBitRateArgument(double bitrateMbps) {
  final clamped = bitrateMbps.clamp(minVideoBitrateMbps, maxVideoBitrateMbps);
  final bitsPerSecond = (clamped * 1000000).round();
  return '--video-bit-rate=$bitsPerSecond';
}

/// Per-app virtual display geometry: `--new-display=<w>x<h>/<dpi>`.
String scrcpyNewDisplayArgument({
  int width = 1280,
  int height = 720,
  int dpi = 240,
}) => '--new-display=${width}x$height/$dpi';

/// Caps the mirrored frame rate.
String scrcpyMaxFpsArgument(int fps) => '--max-fps=${fps.clamp(15, 120)}';

/// Selects the video codec scrcpy streams with.
String scrcpyVideoCodecArgument(String codec) {
  const allowed = {'h264', 'h265', 'av1'};
  final normalized = codec.toLowerCase().trim();
  return '--video-codec=${allowed.contains(normalized) ? normalized : 'h264'}';
}

/// Keeps the physical screen awake while a mirror is active.
const scrcpyStayAwakeArgument = '--stay-awake';

/// Turns the physical screen off while mirroring to this host.
const scrcpyTurnScreenOffArgument = '--turn-screen-off';

/// [value] is one of the persisted `video_display_*` settings entries.
String scrcpyDisplayArgument(Map<String, num?> value) =>
    scrcpyNewDisplayArgument(
      width: value['width']?.toInt() ?? 1280,
      height: value['height']?.toInt() ?? 720,
      dpi: value['dpi']?.toInt() ?? 240,
    );
