/// The two official interface languages of Scanora.
class AppLanguage {
  final String code;
  final String englishName;
  final String nativeName;

  const AppLanguage({
    required this.code,
    required this.englishName,
    required this.nativeName,
  });

  /// Simple language names shown in selection lists.
  String get displayName => code == 'en' ? 'English' : 'Persian';

  static const AppLanguage english = AppLanguage(
    code: 'en',
    englishName: 'English',
    nativeName: 'English',
  );

  static const AppLanguage persian = AppLanguage(
    code: 'fa',
    englishName: 'Persian',
    nativeName: 'فارسی',
  );

  static const List<AppLanguage> all = [english, persian];

  static AppLanguage byCode(String code) =>
      all.firstWhere((l) => l.code == code, orElse: () => english);
}
