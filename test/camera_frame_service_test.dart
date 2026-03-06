import 'dart:async';

import 'package:aeyes/services/camera_frame_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dispatchLatest sends only the newest pending frame', () async {
    var now = DateTime(2026, 3, 6, 12, 0, 0);
    final scheduler = FrameSendScheduler<String>(
      minInterval: const Duration(milliseconds: 400),
      now: () => now,
    );
    final sent = <String>[];

    scheduler.push('first');
    scheduler.push('second');

    await scheduler.dispatchLatest((value) async {
      sent.add(value);
    });

    expect(sent, ['second']);
  });

  test('dispatchLatest honors the minimum cadence', () async {
    var now = DateTime(2026, 3, 6, 12, 0, 0);
    final scheduler = FrameSendScheduler<String>(
      minInterval: const Duration(milliseconds: 400),
      now: () => now,
    );
    final sent = <String>[];

    scheduler.push('first');
    await scheduler.dispatchLatest((value) async {
      sent.add(value);
    });

    scheduler.push('second');
    await scheduler.dispatchLatest((value) async {
      sent.add(value);
    });

    now = now.add(const Duration(milliseconds: 450));
    await scheduler.dispatchLatest((value) async {
      sent.add(value);
    });

    expect(sent, ['first', 'second']);
  });

  test('latest frame is preserved while a prior dispatch is busy', () async {
    final completer = Completer<void>();
    final scheduler = FrameSendScheduler<String>(
      minInterval: Duration.zero,
    );
    final sent = <String>[];

    scheduler.push('first');
    unawaited(scheduler.dispatchLatest((value) async {
      sent.add(value);
      await completer.future;
    }));

    await Future<void>.delayed(Duration.zero);
    scheduler.push('latest');

    final dispatchedWhileBusy = await scheduler.dispatchLatest((value) async {
      sent.add(value);
    });
    expect(dispatchedWhileBusy, isFalse);

    completer.complete();
    await Future<void>.delayed(Duration.zero);
    await scheduler.dispatchLatest((value) async {
      sent.add(value);
    });

    expect(sent, ['first', 'latest']);
  });
}
