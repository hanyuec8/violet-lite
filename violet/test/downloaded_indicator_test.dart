import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:violet/database/user/download.dart';
import 'package:violet/widgets/article_item/thumbnail.dart';

void main() {
  group('DownloadedIndicatorWidget', () {
    testWidgets('renders check icon only when isDownloaded is true', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 120,
              height: 160,
              child: Stack(
                children: [
                  DownloadedIndicatorWidget(
                    isDownloaded: false,
                    hasReadProgress: false,
                    greyScale: false,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.check), findsNothing);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 120,
              height: 160,
              child: Stack(
                children: [
                  DownloadedIndicatorWidget(
                    isDownloaded: true,
                    hasReadProgress: false,
                    greyScale: false,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.check), findsOneWidget);
    });

    test('Download.downloadVersion notifies listeners on append and remove', () {
      final dl = Download();
      var notifications = 0;
      void listener() => notifications++;
      Download.downloadVersion.addListener(listener);
      addTearDown(() => Download.downloadVersion.removeListener(listener));

      final item = DownloadItemModel(result: {'Id': 1, 'URL': '12345', 'State': 0});
      dl.appendDownloaded(12345, item);
      expect(dl.isDownloadedArticle(12345, false), isTrue);
      expect(notifications, equals(1));

      dl.removeDownloaded(12345);
      expect(dl.isDownloadedArticle(12345, false), isFalse);
      expect(notifications, equals(2));
    });
  });
}
