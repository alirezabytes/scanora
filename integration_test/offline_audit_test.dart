import 'captcha_native_test.dart' as captcha;
import 'offline_services_test.dart' as offline;
import 'revision_2_4_native_test.dart' as revision;

/// Local engine checks; no Google session or external service is required.
void main() {
  captcha.main();
  offline.main();
  revision.main();
}
