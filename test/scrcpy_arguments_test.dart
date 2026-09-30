import 'package:flutter_test/flutter_test.dart';

import 'package:androiddex_host/core/scrcpy_arguments.dart';

void main() {
  test('bitrate argument clamps to the supported range', () {
    expect(scrcpyVideoBitRateArgument(0.1), '--video-bit-rate=1000000');
    expect(scrcpyVideoBitRateArgument(64), '--video-bit-rate=32000000');
    expect(scrcpyVideoBitRateArgument(12.5), '--video-bit-rate=12500000');
  });

  test('display argument uses the configured geometry', () {
    expect(scrcpyNewDisplayArgument(), '--new-display=1280x720/240');
    expect(
      scrcpyNewDisplayArgument(width: 1920, height: 1080, dpi: 320),
      '--new-display=1920x1080/320',
    );
    expect(
      scrcpyDisplayArgument({'width': 1920, 'height': 1080, 'dpi': 320}),
      '--new-display=1920x1080/320',
    );
    expect(scrcpyDisplayArgument({}), '--new-display=1280x720/240');
  });

  test('fps and codec arguments clamp and fall back safely', () {
    expect(scrcpyMaxFpsArgument(60), '--max-fps=60');
    expect(scrcpyMaxFpsArgument(5), '--max-fps=15');
    expect(scrcpyMaxFpsArgument(999), '--max-fps=120');
    expect(scrcpyVideoCodecArgument('h265'), '--video-codec=h265');
    expect(scrcpyVideoCodecArgument('H264'), '--video-codec=h264');
    // An unknown codec must not produce a scrcpy command-line error.
    expect(scrcpyVideoCodecArgument('mpeg2'), '--video-codec=h264');
  });
}
