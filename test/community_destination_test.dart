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
}
