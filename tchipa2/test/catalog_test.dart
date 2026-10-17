import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tchipa2/main.dart';

void main() {
  test('bundled catalogue parses', () {
    final raw = File('assets/catalog/products.json').readAsStringSync();
    final list = (jsonDecode(raw) as List).map((e) => Product.fromJson(e as Map<String, dynamic>)).toList();
    expect(list.length, greaterThan(9000));
  });
}
