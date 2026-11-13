import 'package:flutter/material.dart';

/// AppLocalizations handles bilingual translations (English and Persian)
/// with strict language separation and full RTL/LTR awareness.
class AppLocalizations {
  final Locale locale;

  AppLocalizations(this.locale);

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations) ??
        AppLocalizations(const Locale('en'));
  }

  static const _localizedValues = <String, Map<String, String>>{
    'en': {
      'app_title': 'Scanora',
      'choose_language': 'Choose your language',
      'persian': 'Persian',
      'english': 'English (US)',
      'continue_btn': 'Continue',

      // Tabs
      'tab_image_to_text': 'Image to Text',
      'tab_captcha': 'Captcha Solver',
      'tab_image_description': 'Image Description',
      'tab_pdf': 'Documents & Reader',
      'tab_converter': 'Converter',
      'tab_notes': 'Smart Notes',
      'tab_settings': 'Settings',

      // Online / Offline
      'mode_online': 'Online',
      'mode_offline': 'Offline',
      'online_tooltip': 'Online AI mode is active (Tap to switch)',
      'offline_tooltip': 'Offline local engine is active (Tap to switch)',
      'switch_to_online': 'Switch to Online',
      'switch_to_offline': 'Switch to Offline',
      'switched_to_online': 'Switched to Online mode',
      'switched_to_offline': 'Switched to Offline mode',

      // Navigation & Back
      'confirm_exit_title': 'Exit Scanora',
      'confirm_exit_message': 'Are you sure you want to exit the application?',
      'confirm_exit_btn': 'Exit',
      'confirm_exit_section_title': 'Exit Current Section',
      'confirm_exit_section_message':
          'Do you want to exit this section and close the current document or image?',
      'exit_section_btn': 'Exit',
      'cancel': 'Cancel',
      'back': 'Back',
      'close': 'Close',

      // Image to Text (Primary Feature)
      'image_to_text_title': 'Image to Text',
      'image_to_text_desc':
          'Extract text from any photo, document, note, sign, or image.',
      'paste_and_extract': 'Paste & Extract',
      'extract_text_btn': 'Extract Text',
      'extracting_text': 'Extracting text...',
      'copy_text': 'Copy Text',
      'text_copied': 'Text copied to clipboard!',
      'share_text': 'Share',
      'clear': 'Clear',
      'no_text_extracted':
          'No image selected. Select an image to extract text.',
      'words': 'Words',
      'characters': 'Characters',
      'ocr_this_page': 'OCR This Page (Extract Image Text)',
      'ocring_page': 'Running OCR on page image...',
      'scanned_page_detected':
          'Image/scanned content detected on this page. Running OCR automatically...',

      // Captcha Solver
      'captcha_title': 'Captcha Solver',
      'captcha_desc': 'Fast autonomous solver for security codes and captchas.',
      'paste_and_solve': 'Paste & Solve Captcha',
      'solve_captcha_btn': 'Solve Captcha',
      'solving_captcha': 'Solving captcha...',
      'solved_result': 'Solved Result',
      'copy_result': 'Copy Result',
      'result_copied': 'Result copied to clipboard!',
      'auto_copy_label': 'Auto-copy result to clipboard',
      'no_image_selected':
          'No image selected. Paste from clipboard or pick an image.',
      'confidence': 'Confidence',
      'time_elapsed': 'Time Elapsed',
      'solved_by': 'Engine',

      // Document Reader & PDF
      'pdf_title': 'Document & PDF Reader',
      'pdf_desc':
          'Read PDF, Word (.docx, .doc), and Text files with pagination, bookmarks, search, and multi-format export.',
      'open_pdf_btn': 'Open PDF File',
      'open_word_btn': 'Open Word (.docx, .doc)',
      'open_text_btn': 'Open Text File (.txt, .md, .json)',
      'processing_pdf': 'Processing document...',
      'page_stats': 'Page {current} of {total}',
      'next_page': 'Next Page',
      'prev_page': 'Previous Page',
      'go_to_page': 'Go to Page',
      'page_number_prompt': 'Enter page number (1 to {total}):',
      'invalid_page_number': 'Invalid page number',
      'search_text_btn': 'Search',
      'search_query_placeholder': 'Search inside document...',
      'search_results_count': '{count} match(es) found in page {page}',
      'no_search_results': 'No matches found',
      'bookmarks': 'Bookmarks',
      'add_bookmark': 'Bookmark Page',
      'bookmark_added': 'Bookmark saved successfully!',
      'bookmark_label_placeholder': 'Bookmark note or title (optional)',
      'no_bookmarks': 'No bookmarks saved for this document',
      'copy_page': 'Copy Page',
      'copy_all_pages': 'Copy All',
      'export_btn': 'Export',
      'export_options': 'Export',
      'select_format': 'Select Export Format',
      'page_range': 'Page Range',
      'all_pages': 'All Pages (1 to {total})',
      'custom_range': 'Custom Range',
      'from_page': 'From Page',
      'to_page': 'To Page',
      'export_confirm': 'Export',
      'export_success': 'Document exported successfully: {path}',

      // Sources
      'source_camera': 'Camera',
      'source_gallery': 'Gallery',
      'source_clipboard': 'Paste from Clipboard',

      // Settings
      'settings_title': 'Settings',
      'engine_mode_section': 'Engine Mode',
      'work_offline_label': 'Work Offline (Local Engine)',
      'work_offline_desc':
          'Run completely offline without sending any data over the internet.',
      'ai_providers_section': 'AI Vision Provider & Model',
      'active_provider': 'AI Provider',
      'active_model': 'Model',
      'custom_model_label': 'Custom Model Name',
      'custom_model_hint':
          'Enter custom model name (e.g. gemini-2.5-flash, gpt-4o)',
      'custom_model_option': 'Custom Model (Enter below)...',
      'api_key_label': 'API Key',
      'api_key_placeholder': 'Enter your API key here...',
      'custom_base_url': 'Custom Base URL',
      'save_settings': 'Save Settings',
      'settings_saved': 'Settings saved successfully!',
      'preferences_section': 'Preferences',
      'dark_theme': 'Dark Theme',
      'language': 'Language',
      'about_section': 'About Scanora',
      'version': 'Scanora 2.4.15',

      // Errors
      'error_no_api_key':
          'No API key configured for {provider}. Please check Settings or switch to Offline mode.',
      'error_offline_unavailable':
          'Offline recognition did not detect text. Switch to Online mode for AI transcription.',
      'error_general': 'Error: {error}',
    },
    'fa': {
      'app_title': 'اسکنورا',
      'choose_language': 'زبان خود را انتخاب کنید',
      'persian': 'فارسی',
      'english': 'English (US)',
      'continue_btn': 'ورود به برنامه',

      // Tabs
      'tab_image_to_text': 'تبدیل عکس به متن',
      'tab_captcha': 'حل کپچا',
      'tab_image_description': 'توصیف تصویر',
      'tab_pdf': 'اسناد و کتاب‌خوان',
      'tab_converter': 'تبدیل فرمت',
      'tab_notes': 'دفترچه یادداشت',
      'tab_settings': 'تنظیمات',

      // Online / Offline
      'mode_online': 'آنلاین',
      'mode_offline': 'آفلاین',
      'online_tooltip':
          'حالت آنلاین هوش مصنوعی فعال است (برای تغییر ضربه بزنید)',
      'offline_tooltip':
          'حالت موتور محلی آفلاین فعال است (برای تغییر ضربه بزنید)',
      'switch_to_online': 'تغییر به حالت آنلاین',
      'switch_to_offline': 'تغییر به حالت آفلاین',
      'switched_to_online': 'به حالت آنلاین تغییر یافت',
      'switched_to_offline': 'به حالت آفلاین تغییر یافت',

      // Navigation & Back
      'confirm_exit_title': 'خروج از اسکنورا',
      'confirm_exit_message': 'آیا می‌خواهید از برنامه خارج شوید؟',
      'confirm_exit_btn': 'خروج',
      'confirm_exit_section_title': 'خروج از این بخش',
      'confirm_exit_section_message':
          'آیا می‌خواهید از این بخش خارج شده و تصویر یا سند فعلی را ببندید؟',
      'exit_section_btn': 'خروج',
      'cancel': 'انصراف',
      'back': 'بازگشت',
      'close': 'بستن',

      // Image to Text (Primary Feature)
      'image_to_text_title': 'تبدیل عکس به متن',
      'image_to_text_desc':
          'استخراج انواع متن از عکس، اسناد، کتاب، تابلوها، نوشته‌ها و کدهای امنیتی.',
      'paste_and_extract': 'پیست تصویر و استخراج متن',
      'extract_text_btn': 'استخراج متن',
      'extracting_text': 'در حال استخراج متن...',
      'copy_text': 'کپی متن',
      'text_copied': 'متن در کلیپ‌بورد کپی شد!',
      'share_text': 'اشتراک‌گذاری',
      'clear': 'پاکسازی',
      'no_text_extracted':
          'تصویری انتخاب نشده است. یک تصویر انتخاب کنید تا متن آن استخراج شود.',
      'words': 'واژه',
      'characters': 'حرف',
      'ocr_this_page': 'اسکن تصویری این صفحه (OCR عکس‌های صفحه)',
      'ocring_page': 'در حال استخراج متن از تصویر صفحه (OCR)...',
      'scanned_page_detected':
          'صفحه تصویری یا اسکن‌شده تشخیص داده شد. در حال استخراج خودکار متن (OCR)...',

      // Captcha Solver
      'captcha_title': 'حل کپچا',
      'captcha_desc':
          'رمزگشایی سریع و خودکار انواع کدهای امنیتی و کپچاهای عددی و ریاضی.',
      'paste_and_solve': 'پیست و حل فوری کپچا',
      'solve_captcha_btn': 'حل کپچا',
      'solving_captcha': 'در حال حل کپچا...',
      'solved_result': 'پاسخ حل شده',
      'copy_result': 'کپی پاسخ',
      'result_copied': 'پاسخ در کلیپ‌بورد کپی شد!',
      'auto_copy_label': 'کپی خودکار نتیجه در کلیپ‌بورد پس از حل',
      'no_image_selected':
          'تصویری انتخاب نشده است. تصویر کپچا را وارد یا پیست کنید.',
      'confidence': 'میزان دقت',
      'time_elapsed': 'زمان پردازش',
      'solved_by': 'موتور پردازش',

      // Document Reader & PDF
      'pdf_title': 'مطالعه اسناد و کتاب‌خوان',
      'pdf_desc':
          'مطالعه فایل‌های PDF، ورد (.docx, .doc) و متنی با صفحه‌بندی منظم، نشانه‌گذاری، جستجو و خروجی.',
      'open_pdf_btn': 'باز کردن فایل PDF',
      'open_word_btn': 'باز کردن سند ورد (.docx, .doc)',
      'open_text_btn': 'باز کردن فایل متنی (.txt, .md, .json)',
      'processing_pdf': 'در حال پردازش سند...',
      'page_stats': 'صفحه {current} از {total}',
      'next_page': 'صفحه بعد',
      'prev_page': 'صفحه قبل',
      'go_to_page': 'رفتن به صفحه',
      'page_number_prompt': 'شماره صفحه را وارد نمایید (۱ تا {total}):',
      'invalid_page_number': 'شماره صفحه وارد شده نامعتبر است',
      'search_text_btn': 'جستجو در متن',
      'search_query_placeholder': 'کلمه یا متن مورد نظر را بنویسید...',
      'search_results_count': '{count} مورد در صفحه {page} یافت شد',
      'no_search_results': 'موردی یافت نشد',
      'bookmarks': 'نشانک‌ها',
      'add_bookmark': 'نشانه‌گذاری این صفحه',
      'bookmark_added': 'صفحه به لیست نشانک‌ها افزوده شد!',
      'bookmark_label_placeholder': 'یادداشت یا عنوان نشانک (اختیاری)',
      'no_bookmarks': 'هیچ نشانکی برای این سند ثبت نشده است',
      'copy_page': 'کپی این صفحه',
      'copy_all_pages': 'کپی کل متن',
      'export_btn': 'خروجی گرفتن',
      'export_options': 'خروجی گرفتن',
      'select_format': 'فرمت خروجی را انتخاب کنید',
      'page_range': 'محدوده صفحات',
      'all_pages': 'تمام صفحات (۱ تا {total})',
      'custom_range': 'محدوده مشخص',
      'from_page': 'از صفحه',
      'to_page': 'تا صفحه',
      'export_confirm': 'دریافت خروجی',
      'export_success': 'فایل با موفقیت ذخیره شد: {path}',

      // Sources
      'source_camera': 'دوربین',
      'source_gallery': 'گالری',
      'source_clipboard': 'پیست از کلیپ‌بورد',

      // Settings
      'settings_title': 'تنظیمات',
      'engine_mode_section': 'حالت کارکرد برنامه',
      'work_offline_label': 'کارکرد کاملاً آفلاین',
      'work_offline_desc':
          'بدون نیاز به اینترنت و بدون ارسال داده‌ها به خارج از دستگاه کار کنید.',
      'ai_providers_section': 'ارائه‌دهنده و مدل هوش مصنوعی',
      'active_provider': 'سرویس هوش مصنوعی',
      'active_model': 'مدل فعال',
      'custom_model_label': 'نام مدل سفارشی',
      'custom_model_hint':
          'نام مدل مورد نظر را بنویسید (مثلاً gemini-2.5-flash یا gpt-4o)',
      'custom_model_option': 'مدل سفارشی (وارد کردن نام در زیر)...',
      'api_key_label': 'کلید API',
      'api_key_placeholder': 'کلید API را اینجا وارد نمایید...',
      'custom_base_url': 'آدرس اختصاصی (Base URL)',
      'save_settings': 'ذخیره تنظیمات',
      'settings_saved': 'تنظیمات با موفقیت ذخیره شد!',
      'preferences_section': 'ترجیحات و گزینه‌ها',
      'dark_theme': 'تم تیره',
      'language': 'زبان',
      'about_section': 'درباره اسکنورا',
      'version': 'اسکنورا نسخه ۲.۴.۱۵',

      // Errors
      'error_no_api_key':
          'کلید API برای {provider} ثبت نشده است. از تنظیمات کلید را وارد نمایید یا به حالت آفلاین بروید.',
      'error_offline_unavailable':
          'موتور آفلاین متنی تشخیص نداد. به حالت آنلاین بروید یا تصویر واضح‌تری انتخاب کنید.',
      'error_general': 'خطا: {error}',
    },
  };

  String translate(String key, [Map<String, String>? params]) {
    final langCode = locale.languageCode;
    String value =
        _localizedValues[langCode]?[key] ?? _localizedValues['en']?[key] ?? key;
    if (params != null) {
      params.forEach((paramKey, paramVal) {
        value = value.replaceAll('{$paramKey}', paramVal);
      });
    }
    return value;
  }

  /// Returns [fa] when the active language is Persian, otherwise [en].
  /// Used for short, context-specific UI strings that do not need a shared key.
  String tx(String en, String fa) => isPersian ? fa : en;

  bool get isPersian => locale.languageCode == 'fa';
  bool get isRtl =>
      const {'fa', 'ar', 'ur', 'ps', 'ku', 'he'}.contains(locale.languageCode);
  TextDirection get textDirection =>
      isRtl ? TextDirection.rtl : TextDirection.ltr;
}

class AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<AppLocalizations> load(Locale locale) async {
    return AppLocalizations(locale);
  }

  @override
  bool shouldReload(AppLocalizationsDelegate old) => false;
}
