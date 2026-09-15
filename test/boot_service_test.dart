import 'package:flutter_test/flutter_test.dart';

import 'package:androiddex_host/services/boot_service.dart';

void main() {
  test('ADB device parsing includes only authorized online devices', () {
    const output = '''
List of devices attached
USB123 device product:pixel model:Pixel_9 transport_id:1
USB456 unauthorized transport_id:2
192.168.1.20:5555 offline transport_id:3
''';

    expect(parseConnectedAdbDevices(output), ['USB123']);
  });

  test('each reverse mapping is emitted as a separate ADB command', () {
    final commands = buildAdbReverseCommands('USB123');

    expect(commands, hasLength(androidDexReversePorts.length));
    expect(commands.first, ['-s', 'USB123', 'reverse', 'tcp:3698', 'tcp:3698']);
    expect(commands.last, ['-s', 'USB123', 'reverse', 'tcp:3701', 'tcp:3701']);
  });
}
