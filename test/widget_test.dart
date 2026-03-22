import 'package:flutter_test/flutter_test.dart';

import 'package:image_to_pdf/main.dart';

void main() {
  testWidgets('Doc Scanner app shows title', (WidgetTester tester) async {
    await tester.pumpWidget(const DocScannerApp());

    expect(find.text('Doc Scanner'), findsOneWidget);
    expect(find.text('Resim ekle'), findsOneWidget);
    expect(find.text('İşle'), findsOneWidget);
  });
}
