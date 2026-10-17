import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tchipa2/main.dart';

void main() {
  testWidgets('shop shows products once the catalogue is loaded', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(() => Shop.i.load());
    await tester.pumpWidget(const Tchipa2App());
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(ProductCard), findsWidgets);
  });

  testWidgets('shop refreshes when loading finishes after first frame', (tester) async {
    Shop.i.loaded = false;
    await tester.pumpWidget(const Tchipa2App());
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    Shop.i.loaded = true;
    Shop.i.load(); // real reload: notifies listeners when done
    await tester.runAsync(() => Future.delayed(const Duration(seconds: 2)));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
