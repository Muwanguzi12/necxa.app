import 'package:flutter_test/flutter_test.dart';
import 'package:necxa_flutter/screens/profile_screen.dart';

void main() {
  test('profile settings use the official Necxa support and legal links', () {
    expect(necxaSupportUrl, 'https://goobox.necxa.uk');
    expect(necxaTermsUrl, 'https://goobox.necxa.uk/terms');
    expect(necxaPolicyUrl, 'https://goobox.necxa.uk/policy');
    expect(necxaCompanyUrl, 'https://www.necxa.uk');
  });
}
