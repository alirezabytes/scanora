/// One selectable eSpeak-NG language or voice variant.
class EspeakVoiceOption {
  final String code;
  final String nameEn;
  final String nameFa;
  final String group;

  const EspeakVoiceOption(this.code, this.nameEn, this.nameFa,
      [this.group = 'General']);
}

/// Complete catalogs of the official eSpeak-NG 1.52.0 languages and voice variants.
class EspeakVoices {
  EspeakVoices._();

  /// Complete catalog of all 131 standard eSpeak-NG 1.52.0 voices
  static const List<EspeakVoiceOption> languages = [
    EspeakVoiceOption('auto', 'Auto-Detect (Persian + English)',
        'تشخیص خودکار (فارسی + انگلیسی)', 'Recommended'),
    EspeakVoiceOption('fa', 'Persian', 'فارسی (ایران - الفبای فارسی)',
        'Persian & Middle East'),
    EspeakVoiceOption('fa-latn', 'Persian (Pinglish / Latin)',
        'فارسی (پینگلیش / حروف لاتین)', 'Persian & Middle East'),
    EspeakVoiceOption(
        'en-us', 'English (American)', 'انگلیسی (آمریکا)', 'English'),
    EspeakVoiceOption(
        'en-gb', 'English (British)', 'انگلیسی (بریتانیا)', 'English'),
    EspeakVoiceOption('en-gb-x-rp', 'English (Received Pronunciation)',
        'انگلیسی (معیار رسمی RP)', 'English'),
    EspeakVoiceOption('en-gb-scotland', 'English (Scottish)',
        'انگلیسی (اسکاتلند)', 'English'),
    EspeakVoiceOption(
        'en-us-nyc', 'English (New York City)', 'انگلیسی (نیویورک)', 'English'),
    EspeakVoiceOption(
        'en-029', 'English (Caribbean)', 'انگلیسی (کارائیب)', 'English'),
    EspeakVoiceOption(
        'en-gb-x-gbclan', 'English (Lancaster)', 'انگلیسی (لنکستر)', 'English'),
    EspeakVoiceOption('en-gb-x-gbcwmd', 'English (West Midlands)',
        'انگلیسی (وست میدلندز)', 'English'),
    EspeakVoiceOption(
        'ar', 'Arabic (العربية)', 'عربی', 'Persian & Middle East'),
    EspeakVoiceOption(
        'tr', 'Turkish (Türkçe)', 'ترکی استانبولی', 'Persian & Middle East'),
    EspeakVoiceOption('az', 'Azerbaijani (Azərbaycan)', 'ترکی آذربایجانی',
        'Persian & Middle East'),
    EspeakVoiceOption(
        'ku', 'Kurdish (Kurmancî)', 'کردی', 'Persian & Middle East'),
    EspeakVoiceOption('ur', 'Urdu (اردو)', 'اردو', 'Persian & Middle East'),
    EspeakVoiceOption('he', 'Hebrew (עברית)', 'عبری', 'Persian & Middle East'),
    EspeakVoiceOption('tk', 'Turkmen', 'ترکمنی', 'Persian & Middle East'),
    EspeakVoiceOption('uz', 'Uzbek', 'ازبکی', 'Persian & Middle East'),
    EspeakVoiceOption('ky', 'Kyrgyz', 'قرقیزی', 'Persian & Middle East'),
    EspeakVoiceOption('kk', 'Kazakh', 'قزاقی', 'Persian & Middle East'),
    EspeakVoiceOption('ug', 'Uyghur', 'اویغوری', 'Persian & Middle East'),
    EspeakVoiceOption('tt', 'Tatar', 'تاتاری', 'Persian & Middle East'),
    EspeakVoiceOption('ba', 'Bashkir', 'باشقیری', 'Persian & Middle East'),
    EspeakVoiceOption('cv', 'Chuvash', 'چوواشی', 'Persian & Middle East'),
    EspeakVoiceOption('nog', 'Nogai', 'نوغایی', 'Persian & Middle East'),
    EspeakVoiceOption('de', 'German (Deutsch)', 'آلمانی', 'European'),
    EspeakVoiceOption(
        'fr-fr', 'French (France)', 'فرانسوی (فرانسه)', 'European'),
    EspeakVoiceOption(
        'fr-be', 'French (Belgium)', 'فرانسوی (بلژیک)', 'European'),
    EspeakVoiceOption(
        'fr-ch', 'French (Switzerland)', 'فرانسوی (سوئیس)', 'European'),
    EspeakVoiceOption(
        'es', 'Spanish (Spain)', 'اسپانیایی (اسپانیا)', 'European'),
    EspeakVoiceOption('es-419', 'Spanish (Latin America)',
        'اسپانیایی (آمریکای لاتین)', 'European'),
    EspeakVoiceOption('it', 'Italian (Italiano)', 'ایتالیایی', 'European'),
    EspeakVoiceOption(
        'pt', 'Portuguese (Portugal)', 'پرتغالی (پرتغال)', 'European'),
    EspeakVoiceOption(
        'pt-br', 'Portuguese (Brazil)', 'پرتغالی (برزیل)', 'European'),
    EspeakVoiceOption('ru', 'Russian (Русский)', 'روسی', 'European'),
    EspeakVoiceOption('ru-lv', 'Russian (Latvia)', 'روسی (لتونی)', 'European'),
    EspeakVoiceOption('uk', 'Ukrainian (Українська)', 'اوکراینی', 'European'),
    EspeakVoiceOption('be', 'Belarusian', 'بلاروسی', 'European'),
    EspeakVoiceOption('nl', 'Dutch (Nederlands)', 'هلندی', 'European'),
    EspeakVoiceOption('pl', 'Polish (Polski)', 'لهستانی', 'European'),
    EspeakVoiceOption('cs', 'Czech (Čeština)', 'چکی', 'European'),
    EspeakVoiceOption('sk', 'Slovak (Slovenčina)', 'اسلواکی', 'European'),
    EspeakVoiceOption('sv', 'Swedish (Svenska)', 'سوئدی', 'European'),
    EspeakVoiceOption('no', 'Norwegian (Bokmål)', 'نروژی', 'European'),
    EspeakVoiceOption('da', 'Danish (Dansk)', 'دانمارکی', 'European'),
    EspeakVoiceOption('fi', 'Finnish (Suomi)', 'فنلاندی', 'European'),
    EspeakVoiceOption('is', 'Icelandic', 'ایسلندی', 'European'),
    EspeakVoiceOption('fo', 'Faroese', 'فاروئی', 'European'),
    EspeakVoiceOption('el', 'Greek (Ελληνικά)', 'یونانی', 'European'),
    EspeakVoiceOption('grc', 'Greek (Ancient)', 'یونانی باستان', 'European'),
    EspeakVoiceOption('hu', 'Hungarian (Magyar)', 'مجاری', 'European'),
    EspeakVoiceOption('ro', 'Romanian (Română)', 'رومانیایی', 'European'),
    EspeakVoiceOption('bg', 'Bulgarian (Български)', 'بلغاری', 'European'),
    EspeakVoiceOption('sr', 'Serbian (Српски)', 'صربی', 'European'),
    EspeakVoiceOption('hr', 'Croatian (Hrvatski)', 'کرواتی', 'European'),
    EspeakVoiceOption('bs', 'Bosnian', 'بوسنیایی', 'European'),
    EspeakVoiceOption('sl', 'Slovenian', 'اسلوونیایی', 'European'),
    EspeakVoiceOption('mk', 'Macedonian', 'مقدونی', 'European'),
    EspeakVoiceOption('sq', 'Albanian', 'آلبانیایی', 'European'),
    EspeakVoiceOption('et', 'Estonian', 'استونیایی', 'European'),
    EspeakVoiceOption('lv', 'Latvian', 'لتونیایی', 'European'),
    EspeakVoiceOption('lt', 'Lithuanian', 'لیتوانیایی', 'European'),
    EspeakVoiceOption('ltg', 'Latgalian', 'لاتگالی', 'European'),
    EspeakVoiceOption('ca', 'Catalan', 'کاتالان', 'European'),
    EspeakVoiceOption('eu', 'Basque', 'باسکی', 'European'),
    EspeakVoiceOption('an', 'Aragonese', 'آراگونی', 'European'),
    EspeakVoiceOption('ga', 'Gaelic (Irish)', 'ایرلندی', 'European'),
    EspeakVoiceOption('gd', 'Gaelic (Scottish)', 'گیلیک اسکاتلندی', 'European'),
    EspeakVoiceOption('cy', 'Welsh', 'ولزی', 'European'),
    EspeakVoiceOption('mt', 'Maltese', 'مالتی', 'European'),
    EspeakVoiceOption('lb', 'Luxembourgish', 'لوکزامبورگی', 'European'),
    EspeakVoiceOption('la', 'Latin', 'لاتین', 'European'),
    EspeakVoiceOption(
        'hy', 'Armenian (East)', 'ارمنی شرقی', 'Persian & Middle East'),
    EspeakVoiceOption(
        'hyw', 'Armenian (West)', 'ارمنی غربی', 'Persian & Middle East'),
    EspeakVoiceOption(
        'ka', 'Georgian (ქართული)', 'گرجی', 'Persian & Middle East'),
    EspeakVoiceOption('hi', 'Hindi (हिन्दी)', 'هندی', 'Asian'),
    EspeakVoiceOption('bn', 'Bengali (বাংলা)', 'بنگالی', 'Asian'),
    EspeakVoiceOption('pa', 'Punjabi', 'پنجابی', 'Asian'),
    EspeakVoiceOption('gu', 'Gujarati', 'گجراتی', 'Asian'),
    EspeakVoiceOption('mr', 'Marathi', 'مراتی', 'Asian'),
    EspeakVoiceOption('ta', 'Tamil', 'تامیلی', 'Asian'),
    EspeakVoiceOption('te', 'Telugu', 'تلوگو', 'Asian'),
    EspeakVoiceOption('kn', 'Kannada', 'کانارا', 'Asian'),
    EspeakVoiceOption('ml', 'Malayalam', 'مالایالام', 'Asian'),
    EspeakVoiceOption('or', 'Oriya (Odia)', 'اوریه', 'Asian'),
    EspeakVoiceOption('as', 'Assamese', 'آسامی', 'Asian'),
    EspeakVoiceOption('sd', 'Sindhi', 'سندی', 'Asian'),
    EspeakVoiceOption('si', 'Sinhala', 'سینهالی', 'Asian'),
    EspeakVoiceOption('ne', 'Nepali', 'نپالی', 'Asian'),
    EspeakVoiceOption('kok', 'Konkani', 'کونکانی', 'Asian'),
    EspeakVoiceOption(
        'bpy', 'Bishnupriya Manipuri', 'بیشنوپریا مانیپوری', 'Asian'),
    EspeakVoiceOption('cmn', 'Chinese (Mandarin)', 'چینی ماندارین', 'Asian'),
    EspeakVoiceOption('cmn-latn-pinyin', 'Chinese (Mandarin Pinyin)',
        'چینی (پین‌یین)', 'Asian'),
    EspeakVoiceOption('yue', 'Chinese (Cantonese)', 'چینی کانتونی', 'Asian'),
    EspeakVoiceOption('hak', 'Chinese (Hakka)', 'چینی هاکا', 'Asian'),
    EspeakVoiceOption('ja', 'Japanese (日本語)', 'ژاپنی', 'Asian'),
    EspeakVoiceOption('ko', 'Korean (한국어)', 'کره‌ای', 'Asian'),
    EspeakVoiceOption(
        'vi', 'Vietnamese (Northern)', 'ویتنامی (شمالی)', 'Asian'),
    EspeakVoiceOption(
        'vi-vn-x-central', 'Vietnamese (Central)', 'ویتنامی (مرکزی)', 'Asian'),
    EspeakVoiceOption(
        'vi-vn-x-south', 'Vietnamese (Southern)', 'ویتنامی (جنوبی)', 'Asian'),
    EspeakVoiceOption('th', 'Thai (ไทย)', 'تایلندی', 'Asian'),
    EspeakVoiceOption('id', 'Indonesian', 'اندونزیایی', 'Asian'),
    EspeakVoiceOption('ms', 'Malay', 'مالایی', 'Asian'),
    EspeakVoiceOption('my', 'Myanmar (Burmese)', 'برمه‌ای (میانمار)', 'Asian'),
    EspeakVoiceOption('shn', 'Shan (Tai Yai)', 'شان', 'Asian'),
    EspeakVoiceOption('af', 'Afrikaans', 'آفریکانس', 'African & Americas'),
    EspeakVoiceOption('sw', 'Swahili', 'سواحیلی', 'African & Americas'),
    EspeakVoiceOption('am', 'Amharic', 'امهری (اتیوپی)', 'African & Americas'),
    EspeakVoiceOption('om', 'Oromo', 'اورومو', 'African & Americas'),
    EspeakVoiceOption('tn', 'Setswana', 'ستسوانا', 'African & Americas'),
    EspeakVoiceOption(
        'ht', 'Haitian Creole', 'کرئول هائیتی', 'African & Americas'),
    EspeakVoiceOption('pap', 'Papiamento', 'پاپیامنتو', 'African & Americas'),
    EspeakVoiceOption('gn', 'Guarani', 'گوارانی', 'African & Americas'),
    EspeakVoiceOption('qu', 'Quechua', 'کچوا', 'African & Americas'),
    EspeakVoiceOption('quc', "K'iche'", 'کیچه', 'African & Americas'),
    EspeakVoiceOption(
        'nci', 'Nahuatl (Classical)', 'ناهواتل', 'African & Americas'),
    EspeakVoiceOption(
        'chr-US-Qaaa-x-west', 'Cherokee', 'چروکی', 'African & Americas'),
    EspeakVoiceOption('haw', 'Hawaiian', 'هاوایی', 'African & Americas'),
    EspeakVoiceOption('mi', 'Māori', 'مائوری', 'African & Americas'),
    EspeakVoiceOption('kl', 'Greenlandic', 'گرینلندی', 'African & Americas'),
    EspeakVoiceOption('smj', 'Lule Saami', 'سامی لوله', 'European'),
    EspeakVoiceOption('eo', 'Esperanto', 'اسپرانتو', 'Constructed'),
    EspeakVoiceOption('ia', 'Interlingua', 'اینترلینگوا', 'Constructed'),
    EspeakVoiceOption('io', 'Ido', 'ایدو', 'Constructed'),
    EspeakVoiceOption('jbo', 'Lojban', 'لوجبان', 'Constructed'),
    EspeakVoiceOption(
        'lfn', 'Lingua Franca Nova', 'لینگوا فرانکا نوا', 'Constructed'),
    EspeakVoiceOption('piqd', 'Klingon', 'کلینگون', 'Constructed'),
    EspeakVoiceOption('qya', 'Quenya', 'کوئنیا', 'Constructed'),
    EspeakVoiceOption('sjn', 'Sindarin', 'سیندارین', 'Constructed'),
    EspeakVoiceOption('py', 'Pyash', 'پیاش', 'Constructed'),
    EspeakVoiceOption('qdb', 'Lang Belta', 'لنگ بلتا', 'Constructed'),
  ];

  /// Complete catalog of all 94 official eSpeak-NG 1.52.0 voice variants (`!v/*`)
  static const List<EspeakVoiceOption> variants = [
    EspeakVoiceOption('none', 'Default Voice (Standard)',
        'صدای استاندارد پیش‌فرض', 'Standard'),
    // Standard Male Variants
    EspeakVoiceOption('m1', 'Male 1 (m1)', 'مرد ۱ (m1)', 'Male'),
    EspeakVoiceOption('m2', 'Male 2 (m2)', 'مرد ۲ (m2)', 'Male'),
    EspeakVoiceOption('m3', 'Male 3 (m3)', 'مرد ۳ (m3)', 'Male'),
    EspeakVoiceOption('m4', 'Male 4 (m4)', 'مرد ۴ (m4)', 'Male'),
    EspeakVoiceOption('m5', 'Male 5 (m5)', 'مرد ۵ (m5)', 'Male'),
    EspeakVoiceOption('m6', 'Male 6 (m6)', 'مرد ۶ (m6)', 'Male'),
    EspeakVoiceOption('m7', 'Male 7 (m7)', 'مرد ۷ (m7)', 'Male'),
    EspeakVoiceOption('m8', 'Male 8 (m8)', 'مرد ۸ (m8)', 'Male'),
    // Standard Female Variants
    EspeakVoiceOption('f1', 'Female 1 (f1)', 'زن ۱ (f1)', 'Female'),
    EspeakVoiceOption('f2', 'Female 2 (f2)', 'زن ۲ (f2)', 'Female'),
    EspeakVoiceOption('f3', 'Female 3 (f3)', 'زن ۳ (f3)', 'Female'),
    EspeakVoiceOption('f4', 'Female 4 (f4)', 'زن ۴ (f4)', 'Female'),
    EspeakVoiceOption('f5', 'Female 5 (f5)', 'زن ۵ (f5)', 'Female'),
    // Klatt Formant Synthesizer Variants
    EspeakVoiceOption(
        'klatt', 'Klatt Synthesizer 1', 'سینتی‌سایزر Klatt ۱', 'Klatt'),
    EspeakVoiceOption(
        'klatt2', 'Klatt Synthesizer 2', 'سینتی‌سایزر Klatt ۲', 'Klatt'),
    EspeakVoiceOption(
        'klatt3', 'Klatt Synthesizer 3', 'سینتی‌سایزر Klatt ۳', 'Klatt'),
    EspeakVoiceOption(
        'klatt4', 'Klatt Synthesizer 4', 'سینتی‌سایزر Klatt ۴', 'Klatt'),
    EspeakVoiceOption(
        'klatt5', 'Klatt Synthesizer 5', 'سینتی‌سایزر Klatt ۵', 'Klatt'),
    EspeakVoiceOption(
        'klatt6', 'Klatt Synthesizer 6', 'سینتی‌سایزر Klatt ۶', 'Klatt'),
    // Special Effects
    EspeakVoiceOption(
        'whisper', 'Whisper (Male)', 'نجوا / پچ‌پچه (مرد)', 'Effects'),
    EspeakVoiceOption(
        'whisperf', 'Whisper (Female)', 'نجوا / پچ‌پچه (زن)', 'Effects'),
    EspeakVoiceOption(
        'croak', 'Croak (Elderly)', 'صدای خش‌دار (croak)', 'Effects'),
    EspeakVoiceOption('grandpa', 'Grandpa', 'پدربزرگ (grandpa)', 'Effects'),
    EspeakVoiceOption('grandma', 'Grandma', 'مادربزرگ (grandma)', 'Effects'),
    EspeakVoiceOption('fast', 'Fast Test', 'سریع (fast)', 'Effects'),
    EspeakVoiceOption(
        'Demonic', 'Demonic (Deep)', 'بم عمیق (Demonic)', 'Effects'),
    EspeakVoiceOption('announcer', 'Announcement System',
        'بلندگوی اعلامیه (announcer)', 'Effects'),
    EspeakVoiceOption(
        'UniRobot', 'Universal Robot', 'ربات (UniRobot)', 'Effects'),
    // Named Female Character Voices
    EspeakVoiceOption('Alicia', 'Alicia (Female)', 'آلیسیا (زن)', 'Female'),
    EspeakVoiceOption('Andrea', 'Andrea (Female)', 'آندریا (زن)', 'Female'),
    EspeakVoiceOption('Annie', 'Annie (Female)', 'آنی (زن)', 'Female'),
    EspeakVoiceOption('aunty', 'Auntie (Female)', 'آنتی (زن)', 'Female'),
    EspeakVoiceOption('belinda', 'Belinda (Female)', 'بلیندا (زن)', 'Female'),
    EspeakVoiceOption('linda', 'Linda (Female)', 'لیندا (زن)', 'Female'),
    EspeakVoiceOption('steph', 'Steph (Female)', 'استف ۱ (زن)', 'Female'),
    EspeakVoiceOption('steph2', 'Steph 2 (Female)', 'استف ۲ (زن)', 'Female'),
    EspeakVoiceOption('steph3', 'Steph 3 (Female)', 'استف ۳ (زن)', 'Female'),
    EspeakVoiceOption('anika', 'Anika (Female)', 'آنیکا (زن)', 'Female'),
    EspeakVoiceOption(
        'anikaRobot', 'Anika Robot (Female)', 'آنیکا رباتیک (زن)', 'Female'),
    // Named Male Character Voices
    EspeakVoiceOption('adam', 'Adam (Male)', 'آدام (مرد)', 'Male'),
    EspeakVoiceOption('Alex', 'Alex (Male)', 'الکس (مرد)', 'Male'),
    EspeakVoiceOption('Andy', 'Andy (Male)', 'اندی (مرد)', 'Male'),
    EspeakVoiceOption(
        'AnxiousAndy', 'Anxious Andy (Male)', 'اندی مضطرب (مرد)', 'Male'),
    EspeakVoiceOption('antonio', 'Antonio (Male)', 'آنتونیو (مرد)', 'Male'),
    EspeakVoiceOption('benjamin', 'Benjamin (Male)', 'بنجامین (مرد)', 'Male'),
    EspeakVoiceOption('boris', 'Boris (Male)', 'بوریس (مرد)', 'Male'),
    EspeakVoiceOption('caleb', 'Caleb (Male)', 'کالب (مرد)', 'Male'),
    EspeakVoiceOption('david', 'David (Male)', 'دیوید (مرد)', 'Male'),
    EspeakVoiceOption('Denis', 'Denis (Male)', 'دنیس (مرد)', 'Male'),
    EspeakVoiceOption('Diogo', 'Diogo (Male)', 'دیوگو (مرد)', 'Male'),
    EspeakVoiceOption('ed', 'Ed (Male)', 'اد (مرد)', 'Male'),
    EspeakVoiceOption('edward', 'Edward (Male)', 'ادوارد ۱ (مرد)', 'Male'),
    EspeakVoiceOption('edward2', 'Edward 2 (Male)', 'ادوارد ۲ (مرد)', 'Male'),
    EspeakVoiceOption('Gene', 'Gene (Male)', 'جین ۱ (مرد)', 'Male'),
    EspeakVoiceOption('Gene2', 'Gene 2 (Male)', 'جین ۲ (مرد)', 'Male'),
    EspeakVoiceOption('gustave', 'Gustave (Male)', 'گوستاو (مرد)', 'Male'),
    EspeakVoiceOption('Henrique', 'Henrique (Male)', 'هنریکه (مرد)', 'Male'),
    EspeakVoiceOption('Hugo', 'Hugo (Male)', 'هوگو (مرد)', 'Male'),
    EspeakVoiceOption('iven', 'Iven (Male)', 'ایون ۱ (مرد)', 'Male'),
    EspeakVoiceOption('iven2', 'Iven 2 (Male)', 'ایون ۲ (مرد)', 'Male'),
    EspeakVoiceOption('iven3', 'Iven 3 (Male)', 'ایون ۳ (مرد)', 'Male'),
    EspeakVoiceOption('iven4', 'Iven 4 (Male)', 'ایون ۴ (مرد)', 'Male'),
    EspeakVoiceOption('Jacky', 'Jacky (Male)', 'جکی (مرد)', 'Male'),
    EspeakVoiceOption('john', 'John (Male)', 'جان (مرد)', 'Male'),
    EspeakVoiceOption(
        'kaukovalta', 'Kaukovalta (Male)', 'کائوکوالتا (مرد)', 'Male'),
    EspeakVoiceOption('Lee', 'Lee (Male)', 'لی (مرد)', 'Male'),
    EspeakVoiceOption('marcelo', 'Marcelo (Male)', 'مارسلو (مرد)', 'Male'),
    EspeakVoiceOption('Marco', 'Marco (Male)', 'مارکو (مرد)', 'Male'),
    EspeakVoiceOption('Mario', 'Mario (Male)', 'ماریو (مرد)', 'Male'),
    EspeakVoiceOption('max', 'Max (Male)', 'مکس (مرد)', 'Male'),
    EspeakVoiceOption('Michael', 'Michael (Male)', 'مایکل (مرد)', 'Male'),
    EspeakVoiceOption('michel', 'Michel (Male)', 'میشل (مرد)', 'Male'),
    EspeakVoiceOption('miguel', 'Miguel (Male)', 'میگل (مرد)', 'Male'),
    EspeakVoiceOption('Mike', 'Mike (Male)', 'مایک (مرد)', 'Male'),
    EspeakVoiceOption('Nguyen', 'Nguyen (Male)', 'نگوین (مرد)', 'Male'),
    EspeakVoiceOption('norbert', 'Norbert (Male)', 'نوربرت (مرد)', 'Male'),
    EspeakVoiceOption('pablo', 'Pablo (Male)', 'پابلو (مرد)', 'Male'),
    EspeakVoiceOption('paul', 'Paul (Male)', 'پائول (مرد)', 'Male'),
    EspeakVoiceOption('pedro', 'Pedro (Male)', 'پدرو (مرد)', 'Male'),
    EspeakVoiceOption('quincy', 'Quincy (Male)', 'کوئینسی (مرد)', 'Male'),
    EspeakVoiceOption(
        'RicishayMax', 'RicishayMax 1 (Male)', 'ریکیشی مکس ۱ (مرد)', 'Male'),
    EspeakVoiceOption(
        'RicishayMax2', 'RicishayMax 2 (Male)', 'ریکیشی مکس ۲ (مرد)', 'Male'),
    EspeakVoiceOption(
        'RicishayMax3', 'RicishayMax 3 (Male)', 'ریکیشی مکس ۳ (مرد)', 'Male'),
    EspeakVoiceOption('rob', 'Rob (Male)', 'راب (مرد)', 'Male'),
    EspeakVoiceOption('robert', 'Robert (Male)', 'رابرت (مرد)', 'Male'),
    EspeakVoiceOption(
        'robosoft', 'Robosoft 1 (Male)', 'روبوسافت ۱ (مرد)', 'Male'),
    EspeakVoiceOption(
        'robosoft2', 'Robosoft 2 (Male)', 'روبوسافت ۲ (مرد)', 'Male'),
    EspeakVoiceOption(
        'robosoft3', 'Robosoft 3 (Male)', 'روبوسافت ۳ (مرد)', 'Male'),
    EspeakVoiceOption(
        'robosoft4', 'Robosoft 4 (Male)', 'روبوسافت ۴ (مرد)', 'Male'),
    EspeakVoiceOption(
        'robosoft5', 'Robosoft 5 (Male)', 'روبوسافت ۵ (مرد)', 'Male'),
    EspeakVoiceOption(
        'robosoft6', 'Robosoft 6 (Male)', 'روبوسافت ۶ (مرد)', 'Male'),
    EspeakVoiceOption(
        'robosoft7', 'Robosoft 7 (Male)', 'روبوسافت ۷ (مرد)', 'Male'),
    EspeakVoiceOption(
        'robosoft8', 'Robosoft 8 (Male)', 'روبوسافت ۸ (مرد)', 'Male'),
    EspeakVoiceOption('sandro', 'Sandro (Male)', 'ساندرو (مرد)', 'Male'),
    EspeakVoiceOption('shelby', 'Shelby (Male)', 'شلبی (مرد)', 'Male'),
    EspeakVoiceOption('Storm', 'Storm (Male)', 'استورم (مرد)', 'Male'),
    EspeakVoiceOption('travis', 'Travis (Male)', 'تراویس (مرد)', 'Male'),
    EspeakVoiceOption('Tweaky', 'Tweaky (Male)', 'توئیکی (مرد)', 'Male'),
    EspeakVoiceOption('victor', 'Victor (Male)', 'ویکتور (مرد)', 'Male'),
    EspeakVoiceOption('zac', 'Zac (Male)', 'زک (مرد)', 'Male'),
  ];
}
