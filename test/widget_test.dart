import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iot_dashboard/main.dart';

void main() {
  testWidgets('App launches smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const IoTMobileApp());

    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
