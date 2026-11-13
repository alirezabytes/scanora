class DocumentFormats {
  static const images = [
    'png',
    'jpg',
    'jpeg',
    'webp',
    'bmp',
    'tif',
    'tiff',
    'gif'
  ];
  static const text = [
    'txt',
    'md',
    'markdown',
    'json',
    'csv',
    'tsv',
    'xml',
    'html',
    'htm',
    'xhtml',
    'fb2',
    'rtf',
    'srt',
    'vtt',
    'log'
  ];
  static const office = [
    'docx',
    'doc',
    'docm',
    'dotx',
    'pptx',
    'ppt',
    'pptm',
    'ppsx',
    'xlsx',
    'xls',
    'xlsm',
    'xltx',
    'odt',
    'odp',
    'ods'
  ];
  static const all = [
    'pdf',
    'epub',
    ...images,
    ...office,
    ...text,
    'zip',
    'cbz'
  ];
  static String extension(String name) => name.split('.').last.toLowerCase();
}
