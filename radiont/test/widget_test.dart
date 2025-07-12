import 'package:flutter_test/flutter_test.dart';
import 'package:radiont/main.dart'; // Győződj meg róla, hogy a 'radiont' a te projektneved

void main() {
  testWidgets('Radiont App Smoke Test', (WidgetTester tester) async {
    // Építsd fel az appot és válts egy képkockát.
    await tester.pumpWidget(const RadiontApp());

    // Ellenőrizd, hogy a kezdeti rádióállomás neve megjelenik-e.
    expect(find.text('Synthwave FM'), findsOneWidget);
    
    // Ellenőrizd, hogy a Kedvencek felirat megtalálható-e (a felhúzható panelen).
    expect(find.text('Kedvencek'), findsOneWidget);
  });
}