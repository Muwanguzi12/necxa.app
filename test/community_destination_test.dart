import 'package:flutter_test/flutter_test.dart';
import 'package:necxa_flutter/screens/community_screen.dart';

void main() {
  group('Community publishing destination', () {
    test('maps sales publishing to the Shop tab', () {
      expect(communityDestinationTabIndex('shop'), 1);
    });

    test('maps Feed and missing destinations to the Feed tab', () {
      expect(communityDestinationTabIndex('feed'), 0);
      expect(communityDestinationTabIndex(null), 0);
    });
  });

  group('Community responsive layout', () {
    test('uses desktop shell only for wide web viewports', () {
      expect(useCommunityDesktopLayout(1440, isWeb: true), isTrue);
      expect(useCommunityDesktopLayout(979, isWeb: true), isFalse);
      expect(useCommunityDesktopLayout(1440, isWeb: false), isFalse);
    });

    test('constrains modal content on browser-sized viewports', () {
      expect(communityModalMaxWidth(1440, isWeb: true), 680);
      expect(communityModalMaxWidth(600, isWeb: true), 600);
      expect(communityModalMaxWidth(1440, isWeb: false), 1440);
    });
  });
}
