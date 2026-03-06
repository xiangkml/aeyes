import 'package:aeyes/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('App renders and disposes cleanly', (WidgetTester tester) async {
    await tester.pumpWidget(const AEyesApp());

    expect(find.text('AEyes'), findsOneWidget);
    expect(find.text('Tap to start'), findsOneWidget);
    expect(find.byIcon(Icons.visibility), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
