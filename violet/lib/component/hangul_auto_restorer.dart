// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

import 'package:violet/settings/settings.dart';
import 'package:violet/src/rust/api/hangul.dart' as rust_hangul;
import 'package:violet/src/rust/frb_generated.dart';

/// 원작자 `displant.rs` 기반 한글·영타 양방향 자동 복원기.
class HangulAutoRestorer {
  static const List<String> _initials = [
    'r', 'R', 's', 'e', 'E', 'f', 'a', 'q', 'Q', 't',
    'T', 'd', 'w', 'W', 'c', 'z', 'x', 'v', 'g',
  ];

  static const List<String> _medials = [
    'k', 'o', 'i', 'O', 'j', 'p', 'u', 'P', 'h', 'hk', 'ho',
    'hl', 'y', 'n', 'nj', 'np', 'nl', 'b', 'm', 'ml', 'l',
  ];

  static const List<String> _finalsLossless = [
    '', 'r', 'R', 'rt', 's', 'sw', 'sg', 'e', 'f', 'fr', 'fa', 'fq',
    'ft', 'fx', 'fv', 'fg', 'a', 'q', 'qt', 't', 'T', 'd', 'w', 'c',
    'z', 'x', 'v', 'g',
  ];

  static const List<String> _lettersLossless = [
    'r', 'R', 'rt', 's', 'sw', 'sg', 'e', 'E', 'f', 'fr', 'fa', 'fq',
    'ft', 'fx', 'fv', 'fg', 'a', 'q', 'Q', 'qt', 't', 'T', 'd', 'w',
    'W', 'c', 'z', 'x', 'v', 'g', 'k', 'o', 'i', 'O', 'j', 'p', 'u',
    'P', 'h', 'hk', 'ho', 'hl', 'y', 'n', 'nj', 'np', 'nl', 'b', 'm',
    'ml', 'l',
  ];

  static const String _initialJamo = 'ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ';

  static const Set<String> validPrefixes = {
    'female', 'male', 'tag', 'lang', 'language', 'series', 'artist',
    'group', 'uploader', 'character', 'type', 'class', 'id', 'date',
    'published', 'page', 'order', 'random',
  };

  static bool get _useRust {
    try {
      return RustLib.instance.initialized;
    } catch (_) {
      return false;
    }
  }

  static bool _isSyllable(int rune) => rune >= 0xAC00 && rune <= 0xD7A3;
  static bool _isCompatJamo(int rune) => rune >= 0x3131 && rune <= 0x3163;

  static (int, int)? _longest(String text, List<String> table) {
    int bestIdx = -1;
    int bestLen = 0;
    for (var i = 0; i < table.length; i++) {
      final key = table[i];
      if (key.isNotEmpty && text.startsWith(key) && key.length > bestLen) {
        bestIdx = i;
        bestLen = key.length;
      }
    }
    return bestIdx >= 0 ? (bestIdx, bestLen) : null;
  }

  static String keyboardToHangul(String text) {
    if (text.isEmpty) return '';
    if (_useRust) {
      return rust_hangul.restoreHangulTypo(input: text);
    }
    final buf = StringBuffer();
    var rest = text;
    while (rest.isNotEmpty) {
      final initMatch = _longest(rest, _initials);
      if (initMatch != null) {
        final afterInit = rest.substring(initMatch.$2);
        final medMatch = _longest(afterInit, _medials);
        if (medMatch != null) {
          final tail = afterInit.substring(medMatch.$2);
          var finIdx = 0;
          var finLen = 0;
          for (var i = 1; i < _finalsLossless.length; i++) {
            final fk = _finalsLossless[i];
            if (fk.isNotEmpty &&
                tail.startsWith(fk) &&
                _longest(tail.substring(fk.length), _medials) == null &&
                fk.length > finLen) {
              finIdx = i;
              finLen = fk.length;
            }
          }
          final code =
              0xAC00 + ((initMatch.$1 * 21 + medMatch.$1) * 28 + finIdx);
          buf.writeCharCode(code);
          rest = tail.substring(finLen);
        } else {
          buf.write(_initialJamo[initMatch.$1]);
          rest = afterInit;
        }
      } else {
        final medMatch = _longest(rest, _medials);
        if (medMatch != null) {
          buf.writeCharCode(0x314F + medMatch.$1);
          rest = rest.substring(medMatch.$2);
        } else {
          final firstRune = rest.runes.first;
          final s = String.fromCharCode(firstRune);
          buf.write(s);
          rest = rest.substring(s.length);
        }
      }
    }
    return buf.toString();
  }

  static String disassembleLossless(String input) {
    if (input.isEmpty) return '';
    if (_useRust) {
      return rust_hangul.disassembleHangulLossless(input: input);
    }
    final buf = StringBuffer();
    for (final rune in input.runes) {
      if (_isSyllable(rune)) {
        final u = rune - 0xAC00;
        buf.write(_initials[u ~/ (21 * 28)]);
        buf.write(_medials[(u % (21 * 28)) ~/ 28]);
        buf.write(_finalsLossless[(u % (21 * 28)) % 28]);
      } else if (_isCompatJamo(rune)) {
        final idx = rune - 0x3131;
        if (idx >= 0 && idx < _lettersLossless.length) {
          buf.write(_lettersLossless[idx]);
        } else {
          buf.writeCharCode(rune);
        }
      } else {
        buf.writeCharCode(rune);
      }
    }
    return buf.toString();
  }

  static String? tryRestoreKoreanWord(String value) {
    if (value.isEmpty || !RegExp(r'[A-Za-z]').hasMatch(value)) return null;
    if (_useRust) {
      return rust_hangul.analyzeSearchToken(token: value).restoredHangul;
    }
    final norm = value.split('').map((c) {
      if ('REQTWOP'.contains(c)) return c;
      final code = c.codeUnitAt(0);
      if (code >= 65 && code <= 90) return c.toLowerCase();
      return c;
    }).join();
    final converted = keyboardToHangul(norm);
    if (converted == value) return null;
    var syllables = 0;
    for (final r in converted.runes) {
      if (_isCompatJamo(r)) return null;
      if (_isSyllable(r)) syllables++;
    }
    return syllables > 0 ? converted : null;
  }

  static rust_hangul.RestoredSearchToken analyzeToken(String token) {
    if (_useRust) {
      return rust_hangul.analyzeSearchToken(token: token);
    }
    final trimmed = token.trim();
    if (trimmed.isEmpty) {
      return const rust_hangul.RestoredSearchToken(
        original: '',
        rawValue: '',
        disassembledKey: '',
      );
    }
    final neg = trimmed.startsWith('-');
    final sign = neg ? '-' : '';
    final core = neg ? trimmed.substring(1) : trimmed;

    final opMatch = RegExp(r'[><=]').firstMatch(core);
    if (opMatch != null && !core.contains(':')) {
      final lhs =
          disassembleLossless(core.substring(0, opMatch.start)).toLowerCase();
      if ({'page', 'id', 'date', 'published'}.contains(lhs)) {
        final rhs = disassembleLossless(core.substring(opMatch.start));
        final expr = '$sign$lhs$rhs';
        return rust_hangul.RestoredSearchToken(
          original: trimmed,
          normalizedPrefix: lhs,
          rawValue: rhs,
          disassembledKey: disassembleLossless(trimmed),
          restoredExpression: expr != trimmed ? expr : null,
        );
      }
    }

    final colonIdx = core.indexOf(':');
    if (colonIdx > 0) {
      final pfx =
          disassembleLossless(core.substring(0, colonIdx)).toLowerCase();
      final val = core.substring(colonIdx + 1);
      if (validPrefixes.contains(pfx)) {
        final isEnumOrNum = {
          'page', 'id', 'date', 'published', 'lang', 'language', 'type', 'class'
        }.contains(pfx);
        final restoredKor = isEnumOrNum ? null : tryRestoreKoreanWord(val);
        final valExpr = isEnumOrNum ? disassembleLossless(val) : val;
        final rebuilt = '$sign$pfx:$valExpr';
        return rust_hangul.RestoredSearchToken(
          original: trimmed,
          normalizedPrefix: pfx,
          rawValue: val,
          restoredHangul: restoredKor,
          disassembledKey: disassembleLossless(val),
          restoredExpression: rebuilt != trimmed ? rebuilt : null,
        );
      }
    }

    final dis = disassembleLossless(core);
    final disLower = dis.toLowerCase();
    return rust_hangul.RestoredSearchToken(
      original: trimmed,
      rawValue: core,
      restoredHangul: tryRestoreKoreanWord(core),
      disassembledKey: dis,
      restoredExpression: (disLower != core && validPrefixes.contains(disLower))
          ? '$sign$disLower'
          : null,
    );
  }

  static String normalizeQuery(String query) {
    if (!Settings.enableHangulTypoRestore.value || query.trim().isEmpty) {
      return query;
    }
    if (_useRust) {
      return rust_hangul.normalizeSearchQueryTypos(query: query);
    }
    return query.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).map((tok) {
      var lead = '';
      var trail = '';
      var s = tok;
      while (s.startsWith('(')) {
        lead += '(';
        s = s.substring(1);
      }
      while (s.endsWith(')')) {
        trail = ')$trail';
        s = s.substring(0, s.length - 1);
      }
      if (s.isEmpty) return tok;
      final dis = disassembleLossless(s);
      if (s.toLowerCase() != 'or' && dis.toLowerCase() == 'or') {
        return '${lead}or$trail';
      }
      final analyzed = analyzeToken(s);
      if (analyzed.restoredExpression != null) {
        return '$lead${analyzed.restoredExpression}$trail';
      }
      return tok;
    }).join(' ');
  }
}