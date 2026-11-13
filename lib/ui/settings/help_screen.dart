import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../widgets/accessible_disclosure.dart';

class HelpScreen extends StatefulWidget {
  const HelpScreen({super.key});
  @override
  State<HelpScreen> createState() => _HelpScreenState();
}

class _HelpScreenState extends State<HelpScreen> {
  String _query = '';
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final entries = <(String, String)>[
      (
        l.tx('Use Scanora without internet', 'استفاده بدون اینترنت'),
        l.tx(
            'Turn on Work offline in Settings → General. You can read photos and books, solve simple text codes, record voice notes and listen to text. No Google account is needed.',
            'در تنظیمات ← عمومی، کار بدون اینترنت را روشن کنید. می‌توانید عکس و کتاب بخوانید، کدهای متنی ساده را حل کنید، یادداشت صوتی ضبط کنید و به متن گوش دهید. حساب گوگل لازم نیست.')
      ),
      (
        l.tx('Choose online or offline camera reading',
            'انتخاب خواندن آنلاین یا آفلاین دوربین'),
        l.tx(
            'Both live reading and book scanning follow Work offline in Settings. When it is off, they use your selected online service. Hold the camera steady and keep the whole page in view. Reading starts automatically.',
            'خوانش زنده و اسکن کتاب از انتخاب کار بدون اینترنت در تنظیمات پیروی می‌کنند. وقتی خاموش باشد از سرویس آنلاین انتخابی شما استفاده می‌شود. دوربین را ثابت بگیرید و تمام صفحه را در کادر قرار دهید. خواندن خودکار شروع می‌شود.')
      ),
      (
        l.tx('Get a clearer reading', 'خواندن دقیق‌تر'),
        l.tx(
            'Use even light, avoid glare and bring small text closer. Scanora reads Persian, English and mixed text. If a result seems incomplete, reposition the camera and wait for the next reading.',
            'نور یکنواخت باشد، بازتاب نور را کم کنید و نوشتهٔ ریز را نزدیک‌تر بگیرید. برنامه فارسی، انگلیسی و متن ترکیبی را می‌خواند. اگر نتیجه ناقص است، جای دوربین را تنظیم کنید و منتظر خواندن دوباره بمانید.')
      ),
      (
        l.tx('Use your screen reader', 'استفاده از صفحه‌خوان'),
        l.tx(
            'Turn off Built-in audio reader to use your screen reader. Move between the text paragraphs and use Previous Page and Next Page to change pages. New camera results are announced automatically.',
            'برای استفاده از صفحه‌خوان، خوانش صوتی داخلی را خاموش کنید. میان بندهای متن حرکت کنید و با دکمه‌های صفحهٔ قبل و بعد صفحه را عوض کنید. نتیجهٔ جدید دوربین خودکار اعلام می‌شود.')
      ),
      (
        l.tx(
            'Choose whether progress is announced', 'انتخاب اعلام درصد پیشرفت'),
        l.tx(
            'Open Settings → Reading & Playback and change Announce progress. When it is off, progress stays visible and can be checked when you want. Completion and errors are still announced.',
            'در تنظیمات ← خوانش و پخش صوتی، اعلام درصد پیشرفت را تغییر دهید. اگر خاموش باشد، درصد روی صفحه باقی می‌ماند و هر وقت بخواهید می‌توانید آن را بررسی کنید. پایان کار و خطاها همچنان اعلام می‌شوند.')
      ),
      (
        l.tx('Open a book and select pages', 'بازکردن کتاب و انتخاب صفحات'),
        l.tx(
            'Open your file, enter Start Page and End Page, then start reading. Some pages already contain text and are ready quickly. Choose Read every selected page again if their text is incomplete. The result reports successful and failed pages.',
            'فایل را باز کنید، صفحهٔ شروع و پایان را وارد کنید و خواندن را آغاز کنید. بعضی صفحه‌ها از قبل متن دارند و زود آماده می‌شوند. اگر متن ناقص است، خواندن دوبارهٔ همهٔ صفحات انتخابی را علامت بزنید. نتیجه، تعداد صفحات موفق و ناموفق را اعلام می‌کند.')
      ),
      (
        l.tx('Scan a book with spoken guidance', 'اسکن کتاب با راهنمای صوتی'),
        l.tx(
            'Place the book on a steady surface and follow the spoken directions. Wait until the page is saved before turning it. The next page is saved automatically when it becomes steady. Finish scanning to open your book.',
            'کتاب را روی سطح ثابت بگذارید و راهنمای صوتی را دنبال کنید. پیش از ورق‌زدن منتظر اعلام ذخیرهٔ صفحه بمانید. صفحهٔ بعد پس از ثابت‌شدن خودکار ذخیره می‌شود. با پایان اسکن، کتاب را باز کنید.')
      ),
      (
        l.tx('Connect Scanora Cloud', 'اتصال ابر اسکنورا'),
        l.tx(
            'Choose your Google account in Scanora Cloud settings. When you use Scanora Cloud, Google reads the image and creates a temporary document in your Google Drive. Scanora asks Google to delete the document after reading. If it is still there, you can delete it from your Drive.',
            'در تنظیمات ابر اسکنورا، حساب گوگل خود را انتخاب کنید. وقتی از ابر اسکنورا استفاده می‌کنید، گوگل تصویر را می‌خواند و سندی موقت در گوگل درایو خودتان می‌سازد. اسکنورا بعد از خواندن از گوگل می‌خواهد سند را حذف کند. اگر سند باقی ماند، می‌توانید آن را در درایو خودتان حذف کنید.')
      ),
      (
        l.tx('Read security codes', 'خواندن کدهای امنیتی'),
        l.tx(
            'Choose a picture of a text code or a simple calculation. Review the result before using it. Heavy distortion and unusual writing can cause mistakes. Challenges that ask you to select several pictures are not supported.',
            'تصویر کد متنی یا محاسبهٔ ساده را انتخاب کنید. پیش از استفاده، نتیجه را بررسی کنید. نوشتهٔ بسیار مخدوش یا غیرمعمول می‌تواند اشتباه خوانده شود. چالش انتخاب چند تصویر پشتیبانی نمی‌شود.')
      ),
      (
        l.tx('Ask about a picture', 'پرسش دربارهٔ تصویر'),
        l.tx(
            'Without internet you can ask about recognized objects, approximate counts, positions, colors and text. Online mode can give more detailed descriptions. Image answers may contain mistakes.',
            'بدون اینترنت می‌توانید دربارهٔ اشیای شناخته‌شده، تعداد تقریبی، جای اشیا، رنگ و متن بپرسید. حالت آنلاین می‌تواند توضیح بیشتری بدهد. پاسخ تصویری ممکن است اشتباه داشته باشد.')
      ),
      (
        l.tx('Record a voice note', 'ضبط یادداشت صوتی'),
        l.tx(
            'Open Voice Note, start recording and speak near the microphone in a quiet place. Stop recording to turn speech into text. You can choose Persian, English or automatic language detection. A lighter reading option is available in Settings if processing is slow.',
            'یادداشت صوتی را باز و ضبط را شروع کنید. در محیط آرام، نزدیک میکروفون صحبت کنید. برای تبدیل گفتار به متن، ضبط را متوقف کنید. فارسی، انگلیسی یا تشخیص خودکار زبان قابل انتخاب است. اگر پردازش کند است، گزینهٔ سبک‌تر را در تنظیمات انتخاب کنید.')
      ),
      (
        l.tx('Change the reading voice', 'تغییر صدای خواندن'),
        l.tx(
            'Open Settings → eSpeak-NG. Choose a language and voice, then change speed, pitch or volume. Use Test voice to hear your changes. Punctuation and number reading can also be adjusted.',
            'تنظیمات ← eSpeak-NG را باز کنید. زبان و صدا را انتخاب و سرعت، زیر و بمی یا بلندی را تغییر دهید. با آزمایش صدا تغییرات را بشنوید. خواندن علائم و اعداد هم قابل تنظیم است.')
      ),
      (
        l.tx('Find saved books and audio', 'پیداکردن کتاب و صوت ذخیره‌شده'),
        l.tx(
            'Saved books and exported files are in Books & Files Manager. Choose Export to save text or audio. Closing a book clears the reading screen and keeps saved files available.',
            'کتاب‌ها و خروجی‌ها در مدیر کتاب‌ها و فایل‌ها هستند. برای ذخیرهٔ متن یا صوت، خروجی را انتخاب کنید. بستن کتاب صفحهٔ خواندن را پاک می‌کند و فایل‌های ذخیره‌شده در دسترس می‌مانند.')
      ),
    ];
    final found = entries
        .where((e) =>
            '${e.$1} ${e.$2}'.toLowerCase().contains(_query.toLowerCase()))
        .toList();
    return Scaffold(
        appBar:
            AppBar(title: Text(l.tx('Help & FAQ', 'راهنما و پرسش‌های رایج'))),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          Semantics(
              header: true,
              child: Text(
                  l.tx('Read, scan and listen with confidence',
                      'راهنمای خواندن، اسکن و شنیدن'),
                  style: Theme.of(context).textTheme.headlineSmall)),
          const SizedBox(height: 16),
          TextField(
              decoration: InputDecoration(
                  labelText: l.tx('Search help', 'جستجوی راهنما'),
                  prefixIcon: const Icon(Icons.search)),
              onChanged: (v) => setState(() => _query = v)),
          const SizedBox(height: 16),
          if (found.isEmpty)
            Text(l.tx('No matching topics.', 'موضوعی یافت نشد.')),
          for (final e in found)
            Card(
                child: AccessibleDisclosure(
                    key: ValueKey(e.$1),
                    title: e.$1,
                    child: Text(e.$2, style: const TextStyle(height: 1.7)))),
        ]));
  }
}
