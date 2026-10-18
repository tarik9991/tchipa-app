import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tchipa2/main.dart';

void main() {
  test('bundled catalogue parses', () {
    final raw = File('assets/catalog/products.json').readAsStringSync();
    final list = (jsonDecode(raw) as List).map((e) => Product.fromJson(e as Map<String, dynamic>)).toList();
    // Only albums whose photos are on the VPS are kept (build_catalog.py):
    // every product must show a non-empty gallery.
    expect(list.length, greaterThan(7000));
    for (final p in list) {
      expect(p.photoCount, greaterThan(0), reason: '${p.store}/${p.id}');
    }
  });
}
