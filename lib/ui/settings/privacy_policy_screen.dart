import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../widgets/accessible_disclosure.dart';
import 'widgets/settings_page.dart';

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final sections = [
      (
        l.tx('Your privacy at a glance', 'حریم خصوصی شما در یک نگاه'),
        l.tx(
          'Your data is never sent to or stored on a Scanora server. We, the makers of Scanora, have no access through the app to your private information, including your photos, files, recordings, notes or the contents of your Google account.',
          'هیچ‌یک از داده‌های شما به سرور اسکنورا فرستاده یا در آن ذخیره نمی‌شود. ما، سازندگان اسکنورا، از طریق برنامه به اطلاعات خصوصی شما دسترسی نداریم. این شامل عکس‌ها، فایل‌ها، صداهای ضبط‌شده، یادداشت‌ها و محتوای حساب گوگل شما می‌شود.',
        ),
      ),
      (
        l.tx('When you work without internet', 'وقتی بدون اینترنت کار می‌کنید'),
        l.tx(
          'With Work offline on, Scanora reads text in photos and book pages and turns recordings into text on your phone or computer. Your notes, reading history, settings, saved files and app error logs stay on that device.',
          'وقتی «کار بدون اینترنت» روشن است، اسکنورا نوشته‌های عکس‌ها و صفحه‌های کتاب را روی همان گوشی یا رایانه می‌خواند و صداهای ضبط‌شده را به متن تبدیل می‌کند. یادداشت‌ها، سابقهٔ مطالعه، تنظیمات، فایل‌هایی که ذخیره می‌کنید و گزارش‌های خطای برنامه هم روی دستگاه شما می‌مانند.',
        ),
      ),
      (
        l.tx('When you use an online service',
            'وقتی از سرویس آنلاین استفاده می‌کنید'),
        l.tx(
          'When you use an online tool, Scanora sends the information needed to do the job directly to the service you chose. For example, to turn a photo into text, it sends the image. To turn a voice note into text, it sends the recording. When you ask about a picture, it can send the picture and your question. That service decides how long it keeps what it receives under its own privacy policy.',
          'وقتی از ابزار آنلاین استفاده می‌کنید، اسکنورا فقط اطلاعات لازم برای انجام همان کار را مستقیم به سرویس انتخابی شما می‌فرستد. برای تبدیل عکس به متن، تصویر فرستاده می‌شود. برای تبدیل یادداشت صوتی به متن، صدای ضبط‌شده فرستاده می‌شود. اگر دربارهٔ عکسی سؤال کنید، ممکن است عکس و پرسش شما فرستاده شوند. مدت نگهداری این اطلاعات به سیاست حریم خصوصی همان سرویس بستگی دارد.',
        ),
      ),
      (
        l.tx('Scanora Cloud and Google Drive', 'ابر اسکنورا و گوگل درایو'),
        l.tx(
          'If you choose Scanora Cloud to read a photo or page, Google receives the image and creates a temporary document in your own Google Drive. Scanora asks Google to delete that document once reading is done. If the document is still there, you can delete it from your Drive.',
          'اگر برای خواندن عکس یا صفحه‌ای «ابر اسکنورا» را انتخاب کنید، تصویر به گوگل می‌رود و یک سند موقت در گوگل درایو خودتان ساخته می‌شود. اسکنورا پس از خواندن از گوگل می‌خواهد سند را حذف کند. اگر سند باقی ماند، می‌توانید آن را در گوگل درایو خودتان حذف کنید.',
        ),
      ),
      (
        l.tx('Connection keys and web links', 'کلیدهای اتصال و پیوندهای وب'),
        l.tx(
          'If you enter a key to connect an online service, Scanora saves it in the app settings on your device and uses it to connect to that service. Connecting a Google account takes place with Google. When you open a web link, Scanora contacts that website to load the page.',
          'اگر برای اتصال به سرویس آنلاینی کلیدی وارد کنید، اسکنورا آن را در تنظیمات روی دستگاه نگه می‌دارد و برای اتصال به همان سرویس به کار می‌برد. اتصال حساب گوگل از طریق خود گوگل انجام می‌شود. اگر پیوندی را باز کنید، اسکنورا برای دریافت صفحه به همان وب‌سایت وصل می‌شود.',
        ),
      ),
      (
        l.tx('Your choices', 'انتخاب‌های شما'),
        l.tx(
          'To keep photos, pages and recordings on your device while Scanora reads them, turn on Work offline in Settings → General. You can disconnect your Google account from Scanora Cloud and remove saved connection keys in Settings. You can delete your saved notes and files and change camera and microphone permissions in your device settings.',
          'اگر می‌خواهید عکس‌ها، صفحه‌ها و صداهای ضبط‌شده هنگام خواندن روی دستگاه بمانند، در تنظیمات ← عمومی «کار بدون اینترنت» را روشن کنید. می‌توانید اتصال حساب گوگل را از بخش ابر اسکنورا قطع و کلیدهای ذخیره‌شده را از تنظیمات پاک کنید. یادداشت‌ها و فایل‌های ذخیره‌شده را هم می‌توانید حذف کنید. اجازهٔ استفاده از دوربین و میکروفون از تنظیمات دستگاه قابل تغییر است.',
        ),
      ),
    ];
    if (defaultTargetPlatform == TargetPlatform.android) {
      return SettingsPage(
        title: l.tx('Privacy Policy', 'سیاست حریم خصوصی'),
        children: [
          for (final (heading, description) in sections)
            AccessibleDisclosure(
              title: heading,
              child: Text(description, style: const TextStyle(height: 1.55)),
            ),
        ],
      );
    }
    return SettingsPage(
      title: l.tx('Privacy Policy', 'سیاست حریم خصوصی'),
      children: [
        // Keep off-screen sections available to keyboard focus in short windows.
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (heading, description) in sections)
              _PrivacySection(heading: heading, description: description),
          ],
        ),
      ],
    );
  }
}

class _PrivacySection extends StatelessWidget {
  final String heading;
  final String description;

  const _PrivacySection({required this.heading, required this.description});

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child:
                Text(heading, style: Theme.of(context).textTheme.titleMedium),
          ),
          const SizedBox(height: 6),
          Text(description, style: const TextStyle(height: 1.55)),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: defaultTargetPlatform != TargetPlatform.windows
          ? content
          : Focus(
              includeSemantics: false,
              child: Builder(builder: (context) {
                final focus = Focus.of(context);
                final focused = focus.hasPrimaryFocus;
                return Semantics(
                  container: true,
                  excludeSemantics: true,
                  focusable: true,
                  focused: focused,
                  onFocus: focus.requestFocus,
                  label: '$heading\n$description',
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: focused
                            ? Theme.of(context).colorScheme.primary
                            : Colors.transparent,
                        width: 2,
                      ),
                    ),
                    child: content,
                  ),
                );
              }),
            ),
    );
  }
}
