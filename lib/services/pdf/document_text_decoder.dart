import 'dart:convert';
import 'dart:typed_data';

class DocumentTextDecoder {
  static String decode(Uint8List bytes) {
    if (bytes.length >= 2) {
      final le = bytes[0] == 0xFF && bytes[1] == 0xFE;
      final be = bytes[0] == 0xFE && bytes[1] == 0xFF;
      if (le || be) {
        final data = ByteData.sublistView(bytes);
        return String.fromCharCodes([
          for (var i = 2; i + 1 < bytes.length; i += 2)
            data.getUint16(i, le ? Endian.little : Endian.big)
        ]);
      }
    }
    try {
      return utf8.decode(bytes).replaceFirst('\uFEFF', '');
    } on FormatException {
      return latin1.decode(bytes);
    }
  }

  /// Reads RTF Unicode escapes, nested groups and declared ANSI code pages.
  /// Formatting metadata and embedded binary objects never become book text.
  static String rtf(Uint8List bytes) {
    final source = latin1.decode(bytes);
    final output = StringBuffer();
    final stack = <(bool, int)>[];
    var skip = false, unicodeFallback = 1, fallback = 0, codePage = 1252;
    const destinations = {
      'fonttbl',
      'colortbl',
      'stylesheet',
      'info',
      'pict',
      'object',
      'filetbl',
      'listtable',
      'listoverridetable',
      'generator',
      'datastore',
      'themedata',
      'colorschememapping'
    };
    void emit(String text) {
      if (fallback > 0) {
        fallback--;
      } else if (!skip) {
        output.write(text);
      }
    }

    var i = 0;
    while (i < source.length) {
      final char = source[i++];
      if (char == '{') {
        stack.add((skip, unicodeFallback));
        continue;
      }
      if (char == '}') {
        if (stack.isNotEmpty) {
          final state = stack.removeLast();
          skip = state.$1;
          unicodeFallback = state.$2;
        }
        continue;
      }
      if (char == '\r' || char == '\n') continue;
      if (char != '\\') {
        emit(char.codeUnitAt(0) >= 128
            ? _ansi(char.codeUnitAt(0), codePage)
            : char);
        continue;
      }
      if (i >= source.length) break;
      final symbol = source[i];
      if (symbol == '*') {
        skip = true;
        i++;
        continue;
      }
      if (symbol == "'" && i + 2 < source.length) {
        final value = int.tryParse(source.substring(i + 1, i + 3), radix: 16);
        if (value != null) emit(_ansi(value, codePage));
        i += 3;
        continue;
      }
      if (symbol == '\\' || symbol == '{' || symbol == '}') {
        i++;
        emit(symbol);
        continue;
      }
      if (!RegExp(r'[a-zA-Z]').hasMatch(symbol)) {
        i++;
        if (symbol == '~') emit(' ');
        if (symbol == '_') emit('-');
        continue;
      }
      final start = i;
      while (i < source.length && RegExp(r'[a-zA-Z]').hasMatch(source[i])) {
        i++;
      }
      final word = source.substring(start, i);
      final numberStart = i;
      if (i < source.length && source[i] == '-') i++;
      while (i < source.length && RegExp(r'\d').hasMatch(source[i])) {
        i++;
      }
      final value = int.tryParse(source.substring(numberStart, i));
      if (i < source.length && source[i] == ' ') i++;
      if (destinations.contains(word)) {
        skip = true;
        continue;
      }
      if (word == 'ansicpg' && value != null) codePage = value;
      if (word == 'uc' && value != null) unicodeFallback = value.clamp(0, 16);
      if (word == 'u' && value != null && !skip) {
        output.writeCharCode(value & 0xFFFF);
        fallback = unicodeFallback;
      }
      if (word == 'par' || word == 'line' || word == 'row') {
        if (!skip) output.writeln();
      }
      if (word == 'tab' || word == 'cell') {
        if (!skip) output.write('\t');
      }
      if (word == 'bin' && value != null) {
        i = (i + value).clamp(0, source.length);
      }
    }
    return output.toString().trim();
  }

  static String _ansi(int value, int codePage) {
    if (value < 128) return String.fromCharCode(value);
    final table = codePage == 1256 ? _cp1256 : _cp1252;
    return String.fromCharCode(table[value - 128]);
  }

  static const List<int> _cp1252 = [
    8364,
    65533,
    8218,
    402,
    8222,
    8230,
    8224,
    8225,
    710,
    8240,
    352,
    8249,
    338,
    65533,
    381,
    65533,
    65533,
    8216,
    8217,
    8220,
    8221,
    8226,
    8211,
    8212,
    732,
    8482,
    353,
    8250,
    339,
    65533,
    382,
    376,
    160,
    161,
    162,
    163,
    164,
    165,
    166,
    167,
    168,
    169,
    170,
    171,
    172,
    173,
    174,
    175,
    176,
    177,
    178,
    179,
    180,
    181,
    182,
    183,
    184,
    185,
    186,
    187,
    188,
    189,
    190,
    191,
    192,
    193,
    194,
    195,
    196,
    197,
    198,
    199,
    200,
    201,
    202,
    203,
    204,
    205,
    206,
    207,
    208,
    209,
    210,
    211,
    212,
    213,
    214,
    215,
    216,
    217,
    218,
    219,
    220,
    221,
    222,
    223,
    224,
    225,
    226,
    227,
    228,
    229,
    230,
    231,
    232,
    233,
    234,
    235,
    236,
    237,
    238,
    239,
    240,
    241,
    242,
    243,
    244,
    245,
    246,
    247,
    248,
    249,
    250,
    251,
    252,
    253,
    254,
    255
  ];
  static const List<int> _cp1256 = [
    8364,
    1662,
    8218,
    402,
    8222,
    8230,
    8224,
    8225,
    710,
    8240,
    1657,
    8249,
    338,
    1670,
    1688,
    1672,
    1711,
    8216,
    8217,
    8220,
    8221,
    8226,
    8211,
    8212,
    1705,
    8482,
    1681,
    8250,
    339,
    8204,
    8205,
    1722,
    160,
    1548,
    162,
    163,
    164,
    165,
    166,
    167,
    168,
    169,
    1726,
    171,
    172,
    173,
    174,
    175,
    176,
    177,
    178,
    179,
    180,
    181,
    182,
    183,
    184,
    185,
    1563,
    187,
    188,
    189,
    190,
    1567,
    1729,
    1569,
    1570,
    1571,
    1572,
    1573,
    1574,
    1575,
    1576,
    1577,
    1578,
    1579,
    1580,
    1581,
    1582,
    1583,
    1584,
    1585,
    1586,
    1587,
    1588,
    1589,
    1590,
    215,
    1591,
    1592,
    1593,
    1594,
    1600,
    1601,
    1602,
    1603,
    224,
    1604,
    226,
    1605,
    1606,
    1607,
    1608,
    231,
    232,
    233,
    234,
    235,
    1609,
    1610,
    238,
    239,
    1611,
    1612,
    1613,
    1614,
    244,
    1615,
    1616,
    247,
    1617,
    249,
    1618,
    251,
    252,
    8206,
    8207,
    1746
  ];
}
