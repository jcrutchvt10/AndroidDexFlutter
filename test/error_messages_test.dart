import 'package:flutter_test/flutter_test.dart';

import 'package:androiddex_host/core/error_messages.dart';
import 'package:androiddex_host/core/json_read.dart';

void main() {
  test('AndroidDexError renders the user message, not the detail', () {
    const failure = AndroidDexError(
      'Companion app timed out.',
      devDetail: 'ws://127.0.0.1:3699 ETIMEDOUT after 15s',
    );
    expect('$failure', 'Companion app timed out.');
    expect(userMessageFor(failure), 'Companion app timed out.');
    expect(failure.devDetail, contains('127.0.0.1'));
  });

  test('arbitrary exceptions normalise to plain strings', () {
    expect(userMessageFor(StateError('boom')), 'boom');
    expect(userMessageFor(const FormatException('raw stderr')), 'raw stderr');
  });

  test('connection-error heuristic matches the reference classifier', () {
    expect(isConnectionError('adb reverse failed on port 3698'), isTrue);
    expect(isConnectionError('Background service timed out.'), isTrue);
    expect(isConnectionError('Device disconnected.'), isTrue);
    expect(
      isConnectionError('Service module not found. Please reinstall.'),
      isFalse,
    );
    expect(isConnectionError('The app list could not be read.'), isFalse);
  });

  test('json_read tolerates the flat and nested shapes', () {
    final flat = {'type': 'battery_small', 'percentage': 87};
    expect(messageType(flat), 'battery_small');
    expect(readInt(flat, const ['percentage']), 87);

    final nested = {
      'type': 'battery_update',
      'battery': {'percentage': '88', 'charging': 1},
    };
    final battery = readObject(nested, const ['battery']);
    expect(battery, isNotNull);
    expect(readInt(battery!, const ['percentage']), 88);
    expect(readBool(battery, const ['charging']), isTrue);
    expect(isHandshake({'type': 'media.hello'}, 'media.hello'), isTrue);
    expect(
      isHandshake({
        'data': {'type': 'media.hello'},
      }, 'media.hello'),
      isTrue,
    );
  });
}
