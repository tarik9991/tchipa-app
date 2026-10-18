import 'package:flutter_test/flutter_test.dart';
import 'package:tchipa2/main.dart';

void main() {
  final p = Product(
    id: '1',
    title: 'Jordan 12',
    category: 'Sneakers',
    price: 142.57,
    store: 'tmf001',
    photoCount: 1,
    photos: ['abc'],
    code: 'CT8013-002',
  );

  test('price is shown in dollars', () {
    expect(p.priceLabel, '\$142.57');
  });

  test('search ignores case and accents', () {
    expect(p.matches(['jordan', 'ct8013']), isTrue);
    expect(p.matches(['moncler']), isFalse);
  });

  test('order message lists items and total', () {
    final msg = orderMessage([CartLine(p, size: '42', qty: 2)]);
    expect(msg, contains('Jordan 12 (CT8013-002)'));
    expect(msg, contains('Taille 42'));
    expect(msg, contains('Total : \$285.14'));
  });
}
