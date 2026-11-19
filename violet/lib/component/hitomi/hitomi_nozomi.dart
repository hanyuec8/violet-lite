// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:violet/network/wrapper.dart' as http;
import 'package:violet/log/log.dart';
import 'package:violet/src/rust/api/nozomi.dart' as rust_nozomi;

enum SearchSortMode {
  latest,
  popularWeek,
  popularMonth,
  popularYear,
  popularAll,
  popularToday,
}

extension SearchSortModeExtension on SearchSortMode {
  String get label {
    switch (this) {
      case SearchSortMode.latest:
        return '최신순';
      case SearchSortMode.popularWeek:
        return '주간 인기순';
      case SearchSortMode.popularMonth:
        return '월간 인기순';
      case SearchSortMode.popularYear:
        return '연간 인기순';
      case SearchSortMode.popularAll:
        return '역대 인기순';
      case SearchSortMode.popularToday:
        return '일간 인기순';
    }
  }

  String get description {
    switch (this) {
      case SearchSortMode.latest:
        return '최근 업로드된 순서대로 표시';
      case SearchSortMode.popularWeek:
        return '이번 주 가장 인기 있는 작품';
      case SearchSortMode.popularMonth:
        return '이번 달 가장 인기 있는 작품';
      case SearchSortMode.popularYear:
        return '올해 가장 인기 있는 작품';
      case SearchSortMode.popularAll:
        return '역대 누적 최다 조회 작품';
      case SearchSortMode.popularToday:
        return '오늘 실시간 인기 급상승 작품';
    }
  }
}

/// Hitomi Nozomi Range Request Fetcher.
/// Hitomi.la의 `.nozomi` 바이너리 인덱스 파일에서 4바이트 Big-Endian 정수(갤러리 ID)를
/// HTTP Range Header (bytes=start-end)를 이용해 100바이트 단위로 실시간 비동기 로딩합니다.
class HitomiNozomi {
  static const String domain = 'ltn.gold-usergeneratedcontent.net';

  /// Nozomi URL -> 총 작품 수 인메모리 캐시
  static final Map<String, int> _totalCountCache = <String, int>{};

  /// Nozomi URL -> 전체 갤러리 ID 목록 인메모리 LRU 캐시 (최대 40개)
  static final Map<String, List<int>> _fullNozomiCache = <String, List<int>>{};
  static const int _maxFullCacheEntries = 40;

  /// galleriesindex B-Tree 캐시
  static String? _galleriesIndexVersion;
  static DateTime? _galleriesVersionFetchedAt;
  static final Map<String, HitomiBTreeNode> _btreeNodeCache =
      <String, HitomiBTreeNode>{};
  static final Map<String, List<int>> _titleWordCache = <String, List<int>>{};

  @visibleForTesting
  static Future<List<int>> Function(String nozomiUrl)? testFetchAllOverride;

  @visibleForTesting
  static Future<List<int>> Function(String term)? testTitleWordOverride;

  @visibleForTesting
  static void clearCaches() {
    _totalCountCache.clear();
    _fullNozomiCache.clear();
    _galleriesIndexVersion = null;
    _galleriesVersionFetchedAt = null;
    _btreeNodeCache.clear();
    _titleWordCache.clear();
  }

  /// 특정 Nozomi URL에서 전체 갤러리 ID 목록을 가져옵니다 (캐시 우선).
  static Future<List<int>> fetchAllGalleryIds(
    String nozomiUrl, {
    Duration timeout = const Duration(seconds: 8),
    bool throwOnError = false,
  }) async {
    if (testFetchAllOverride != null) {
      return await testFetchAllOverride!(nozomiUrl);
    }

    final cached = _fullNozomiCache.remove(nozomiUrl);
    if (cached != null) {
      _fullNozomiCache[nozomiUrl] = cached;
      return cached;
    }

    try {
      final response = await http.get(
        nozomiUrl,
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Referer': 'https://hitomi.la/',
        },
      ).timeout(timeout);

      if (response.statusCode == 200 || response.statusCode == 206) {
        final ids = parseNozomiBytes(Uint8List.fromList(response.bodyBytes));
        _totalCountCache[nozomiUrl] = ids.length;
        if (_fullNozomiCache.length >= _maxFullCacheEntries) {
          _fullNozomiCache.remove(_fullNozomiCache.keys.first);
        }
        _fullNozomiCache[nozomiUrl] = ids;
        return ids;
      } else if (response.statusCode == 404) {
        _totalCountCache[nozomiUrl] = 0;
        if (_fullNozomiCache.length >= _maxFullCacheEntries) {
          _fullNozomiCache.remove(_fullNozomiCache.keys.first);
        }
        _fullNozomiCache[nozomiUrl] = const <int>[];
        return const <int>[];
      } else {
        Logger.warning(
          '[HitomiNozomi] Non-success full request (${response.statusCode}): $nozomiUrl',
        );
        if (throwOnError) {
          throw Exception('HTTP ${response.statusCode}');
        }
      }
    } catch (e, st) {
      Logger.error('[HitomiNozomi] Exception during full request: $e\n$st');
      if (throwOnError) rethrow;
    }
    return const <int>[];
  }

  /// 특정 Nozomi URL에서 시작 인덱스(0부터 시작하는 갤러리 번호)와 개수를 지정하여 ID 목록을 가져옵니다.
  static Future<List<int>> fetchGalleryIdsByOffset(
    String nozomiUrl,
    int offsetIndex,
    int count,
  ) async {
    try {
      final startByte = offsetIndex * 4;
      final endByte = (offsetIndex + count) * 4 - 1;

      final response = await http.get(
        nozomiUrl,
        headers: {
          'Range': 'bytes=$startByte-$endByte',
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Referer': 'https://hitomi.la/',
        },
      ).timeout(const Duration(seconds: 4));

      if (response.statusCode == 206 || response.statusCode == 200) {
        return parseNozomiBytes(Uint8List.fromList(response.bodyBytes));
      }
    } catch (_) {}
    return [];
  }

  /// 특정 Nozomi URL에서 지정한 페이지 범위(기본 25개 갤러리 ID)를 Range Header로 요청합니다.
  static Future<List<int>> fetchGalleryIds(
    String nozomiUrl,
    int page, {
    int pageSize = 25,
  }) async {
    try {
      final startByte = (page - 1) * pageSize * 4;
      final endByte = page * pageSize * 4 - 1;

      final response = await http.get(
        nozomiUrl,
        headers: {
          'Range': 'bytes=$startByte-$endByte',
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Referer': 'https://hitomi.la/',
        },
      );

      if (response.statusCode == 206 || response.statusCode == 200) {
        // Content-Range 헤더(예: bytes 0-15/36) 또는 Content-Length를 통해 총 작품 수 캐싱
        try {
          final contentRange = response.headers['content-range'];
          if (contentRange != null && contentRange.contains('/')) {
            final totalStr = contentRange.split('/').last.trim();
            final totalBytes = int.tryParse(totalStr);
            if (totalBytes != null && totalBytes > 0) {
              _totalCountCache[nozomiUrl] = totalBytes ~/ 4;
            }
          } else if (response.statusCode == 200) {
            _totalCountCache[nozomiUrl] = response.bodyBytes.length ~/ 4;
          }
        } catch (_) {}

        return parseNozomiBytes(Uint8List.fromList(response.bodyBytes));
      } else {
        if (response.statusCode == 404) {
          _totalCountCache[nozomiUrl] = 0;
          Logger.info(
            '[HitomiNozomi] Nozomi index not found (404): $nozomiUrl',
          );
        } else {
          Logger.warning(
            '[HitomiNozomi] Non-success range request (${response.statusCode}): $nozomiUrl',
          );
        }
      }
    } catch (e, st) {
      Logger.error('[HitomiNozomi] Exception during range request: $e\n$st');
    }
    return [];
  }

  /// 특정 Nozomi 인덱스의 총 작품 수를 반환합니다 (캐시 우선, 부재 시 Range 0-0 요청으로 전체 바이트 수 추출).
  static Future<int?> getTotalCount(String nozomiUrl) async {
    if (_totalCountCache.containsKey(nozomiUrl)) {
      return _totalCountCache[nozomiUrl];
    }
    try {
      final response = await http.get(
        nozomiUrl,
        headers: {
          'Range': 'bytes=0-0',
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Referer': 'https://hitomi.la/',
        },
      ).timeout(const Duration(seconds: 3));

      if (response.statusCode == 200 || response.statusCode == 206) {
        final contentRange = response.headers['content-range'];
        if (contentRange != null && contentRange.contains('/')) {
          final totalStr = contentRange.split('/').last.trim();
          final totalBytes = int.tryParse(totalStr);
          if (totalBytes != null && totalBytes >= 0) {
            final count = totalBytes ~/ 4;
            _totalCountCache[nozomiUrl] = count;
            return count;
          }
        }
        final lengthStr = response.headers['content-length'];
        if (lengthStr != null) {
          final totalBytes = int.tryParse(lengthStr);
          if (totalBytes != null && totalBytes >= 0) {
            final count = totalBytes ~/ 4;
            _totalCountCache[nozomiUrl] = count;
            return count;
          }
        }
      } else if (response.statusCode == 404) {
        _totalCountCache[nozomiUrl] = 0;
        return 0;
      }
    } catch (_) {}
    return null;
  }

  /// 4바이트 Big-Endian 정수 배열을 Dart `List<int>` ID 목록으로 바이트 언패킹(Unpack)합니다.
  /// Rust FFI(`rust_nozomi.parseNozomiBytes`)를 우선 호출하여 Zero-copy 및 SIMD 가속을 수행합니다.
  static List<int> parseNozomiBytes(Uint8List bytes) {
    try {
      return rust_nozomi.parseNozomiBytes(bytes: bytes);
    } catch (_) {
      final ids = <int>[];
      final byteData = ByteData.sublistView(bytes);

      for (var i = 0; i + 4 <= bytes.length; i += 4) {
        final id = byteData.getUint32(i, Endian.big);
        ids.add(id);
      }
      return ids;
    }
  }

  /// 검색어 정규화 유틸리티: 언더스코어를 공백으로 변환하고, URL용 공백을 '%20'으로 안전하게 인코딩합니다.
  static String cleanTerm(String raw) {
    var s = raw.trim();
    if (s.startsWith('"') && s.endsWith('"')) {
      s = s.substring(1, s.length - 1).trim();
    }
    s = s.replaceAll('_', ' ');
    s = s.replaceAll(RegExp(r'\s+'), ' ');
    return s.replaceAll(' ', '%20');
  }

  /// 메인 갤러리 전체 최신 작품 목록 URL 생성
  static String getIndexAllUrl() => 'https://$domain/index-all.nozomi';

  /// 특정 언어별 최신 작품 목록 URL 생성 (예: 'korean')
  static String getLanguageIndexUrl(String language) =>
      'https://$domain/index-$language.nozomi';

  /// 인기순 인덱스 URL 생성 (주간, 월간, 연간, 역대, 일간)
  static String getPopularIndexUrl(SearchSortMode sortMode, [String language = 'korean']) {
    final lang = (language == 'korean' || language == 'japanese' || language == 'english')
        ? language
        : 'all';
    switch (sortMode) {
      case SearchSortMode.popularAll:
        return 'https://$domain/popular-$lang.nozomi';
      case SearchSortMode.popularWeek:
        return 'https://$domain/popular/week-$lang.nozomi';
      case SearchSortMode.popularMonth:
        return 'https://$domain/popular/month-$lang.nozomi';
      case SearchSortMode.popularToday:
        return 'https://$domain/popular/today-$lang.nozomi';
      case SearchSortMode.popularYear:
        return 'https://$domain/popular/year-$lang.nozomi';
      case SearchSortMode.latest:
        return getLanguageIndexUrl(language);
    }
  }

  /// 작가별 최신 작품 목록 URL 생성
  static String getArtistIndexUrl(String artist, [String language = 'all']) {
    final clean = cleanTerm(artist);
    return 'https://$domain/artist/$clean-$language.nozomi';
  }

  /// 그룹별 최신 작품 목록 URL 생성
  static String getGroupIndexUrl(String group, [String language = 'all']) {
    final clean = cleanTerm(group);
    return 'https://$domain/group/$clean-$language.nozomi';
  }

  /// 시리즈별 최신 작품 목록 URL 생성
  static String getSeriesIndexUrl(String series, [String language = 'all']) {
    final clean = cleanTerm(series);
    return 'https://$domain/series/$clean-$language.nozomi';
  }

  /// 캐릭터별 최신 작품 목록 URL 생성
  static String getCharacterIndexUrl(String character, [String language = 'all']) {
    final clean = cleanTerm(character);
    return 'https://$domain/character/$clean-$language.nozomi';
  }

  /// 업로더별 최신 작품 목록 URL 생성
  static String getUploaderIndexUrl(String uploader, [String language = 'all']) {
    final clean = cleanTerm(uploader);
    return 'https://$domain/uploader/$clean-$language.nozomi';
  }

  /// 작품 종류(type: doujinshi, manga, artistcg, gamecg, imageset, anime)별 목록 URL 생성
  static String getTypeIndexUrl(String type, [String language = 'all']) {
    final clean = cleanTerm(type.toLowerCase());
    return 'https://$domain/type/$clean-$language.nozomi';
  }

  /// 특정 태그별 작품 목록 URL 생성 (예: 'female:big breasts' -> 'tag/female:big%20breasts-all.nozomi')
  static String getTagIndexUrl(String tag, [String language = 'all']) {
    var raw = tag.trim();
    if (raw.toLowerCase().startsWith('tag:')) {
      raw = raw.substring(4).trim();
    }
    final cleanTag = cleanTerm(raw);
    return 'https://$domain/tag/$cleanTag-$language.nozomi';
  }

  /// 특정 태그별 작품 목록을 시작 인덱스(offsetIndex)와 개수(count)를 지정하여 가져옵니다.
  static Future<List<int>> fetchTagGalleryIdsByOffset(
    String tag,
    int offsetIndex,
    int count, {
    String language = 'all',
  }) async {
    var raw = tag.trim();
    if (raw.toLowerCase().startsWith('tag:')) {
      raw = raw.substring(4).trim();
    }

    final lower = raw.toLowerCase();
    if (lower.startsWith('female:') || lower.startsWith('male:')) {
      return await fetchGalleryIdsByOffset(
        getTagIndexUrl(raw, language),
        offsetIndex,
        count,
      );
    }

    final femaleIds = await fetchGalleryIdsByOffset(
      getTagIndexUrl('female:$raw', language),
      offsetIndex,
      count,
    );
    if (femaleIds.isNotEmpty) return femaleIds;

    final maleIds = await fetchGalleryIdsByOffset(
      getTagIndexUrl('male:$raw', language),
      offsetIndex,
      count,
    );
    if (maleIds.isNotEmpty) return maleIds;

    return await fetchGalleryIdsByOffset(
      getTagIndexUrl(raw, language),
      offsetIndex,
      count,
    );
  }

  /// 태그의 실제 유효한 Nozomi URL을 탐색하여 반환합니다 (female -> male -> 일반 순).
  static Future<String?> resolveTagNozomiUrl(
    String tag, [
    String language = 'all',
  ]) async {
    var raw = tag.trim();
    if (raw.toLowerCase().startsWith('tag:')) {
      raw = raw.substring(4).trim();
    }
    final lower = raw.toLowerCase();
    if (lower.startsWith('female:') || lower.startsWith('male:')) {
      final url = getTagIndexUrl(raw, language);
      final count = await getTotalCount(url);
      if (count != null && count > 0) return url;
      if (language != 'all') {
        final allUrl = getTagIndexUrl(raw, 'all');
        final allCount = await getTotalCount(allUrl);
        if (allCount != null && allCount > 0) return allUrl;
      }
      return url;
    }

    final femaleUrl = getTagIndexUrl('female:$raw', language);
    final femaleCount = await getTotalCount(femaleUrl);
    if (femaleCount != null && femaleCount > 0) return femaleUrl;

    final maleUrl = getTagIndexUrl('male:$raw', language);
    final maleCount = await getTotalCount(maleUrl);
    if (maleCount != null && maleCount > 0) return maleUrl;

    final generalUrl = getTagIndexUrl(raw, language);
    final generalCount = await getTotalCount(generalUrl);
    if (generalCount != null && generalCount > 0) return generalUrl;

    if (language != 'all') {
      final femaleAll = getTagIndexUrl('female:$raw', 'all');
      final c1 = await getTotalCount(femaleAll);
      if (c1 != null && c1 > 0) return femaleAll;

      final maleAll = getTagIndexUrl('male:$raw', 'all');
      final c2 = await getTotalCount(maleAll);
      if (c2 != null && c2 > 0) return maleAll;

      return getTagIndexUrl(raw, 'all');
    }

    return femaleUrl;
  }

  /// 태그 검색을 스마트하게 처리하는 페처:
  /// 네임스페이스가 없는 일반 태그인 경우 female -> male -> 일반 순으로 자동 Fallback 탐색합니다.
  static Future<List<int>> fetchTagGalleryIds(
    String tag,
    int page, {
    int pageSize = 25,
    String language = 'all',
  }) async {
    return await fetchTagGalleryIdsByOffset(
      tag,
      (page - 1) * pageSize,
      pageSize,
      language: language,
    );
  }

  // ---------------------------------------------------------------------------
  // Hitomi 공식 galleriesindex B-Tree 제목 단어 검색 (search.js 1:1 호환)
  // ---------------------------------------------------------------------------

  static const int _btreeNodeSize = 464;
  static const int _btreeOrder = 16;

  static Uint8List hashSearchTerm(String term) {
    final normalized = term.trim().replaceAll('_', ' ').toLowerCase();
    final digest = sha256.convert(utf8.encode(normalized));
    return Uint8List.fromList(digest.bytes.sublist(0, 4));
  }

  static int _compareBytes(Uint8List a, Uint8List b) {
    final len = math.min(a.length, b.length);
    for (var i = 0; i < len; i++) {
      if (a[i] < b[i]) return -1;
      if (a[i] > b[i]) return 1;
    }
    return 0;
  }

  @visibleForTesting
  static HitomiBTreeNode? decodeBTreeNode(Uint8List data) {
    if (data.length < 8) return null;
    final bd = ByteData.sublistView(data);
    var pos = 0;

    final numKeys = bd.getInt32(pos, Endian.big);
    pos += 4;
    if (numKeys < 0 || numKeys > _btreeOrder) return null;

    final keys = <Uint8List>[];
    for (var i = 0; i < numKeys; i++) {
      if (pos + 4 > data.length) return null;
      final keySize = bd.getInt32(pos, Endian.big);
      pos += 4;
      if (keySize <= 0 || keySize > 32 || pos + keySize > data.length) {
        return null;
      }
      keys.add(data.sublist(pos, pos + keySize));
      pos += keySize;
    }

    if (pos + 4 > data.length) return null;
    final numDatas = bd.getInt32(pos, Endian.big);
    pos += 4;
    if (numDatas < 0 || numDatas > _btreeOrder) return null;

    final datas = <(int offset, int length)>[];
    for (var i = 0; i < numDatas; i++) {
      if (pos + 12 > data.length) return null;
      final offset = bd.getUint64(pos, Endian.big);
      pos += 8;
      final length = bd.getInt32(pos, Endian.big);
      pos += 4;
      datas.add((offset, length));
    }

    final subnodes = <int>[];
    for (var i = 0; i < _btreeOrder + 1; i++) {
      if (pos + 8 > data.length) break;
      subnodes.add(bd.getUint64(pos, Endian.big));
      pos += 8;
    }

    return HitomiBTreeNode(keys: keys, datas: datas, subnodeAddresses: subnodes);
  }

  static Future<String?> _getGalleriesIndexVersion() async {
    final now = DateTime.now();
    if (_galleriesIndexVersion != null &&
        _galleriesVersionFetchedAt != null &&
        now.difference(_galleriesVersionFetchedAt!) <
            const Duration(minutes: 15)) {
      return _galleriesIndexVersion;
    }
    try {
      final res = await http.get(
        'https://$domain/galleriesindex/version?_=${now.millisecondsSinceEpoch}',
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Referer': 'https://hitomi.la/',
        },
      ).timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final ver = res.body.trim();
        if (ver.isNotEmpty) {
          _galleriesIndexVersion = ver;
          _galleriesVersionFetchedAt = now;
          return ver;
        }
      }
    } catch (e) {
      Logger.warning('[HitomiNozomi] galleriesindex version error: $e');
    }
    return _galleriesIndexVersion;
  }

  static Future<HitomiBTreeNode?> _getBTreeNode(
    String version,
    int address,
  ) async {
    final cacheKey = '$version:$address';
    final cached = _btreeNodeCache[cacheKey];
    if (cached != null) return cached;

    try {
      final url = 'https://$domain/galleriesindex/galleries.$version.index';
      final end = address + _btreeNodeSize - 1;
      final res = await http.get(
        url,
        headers: {
          'Range': 'bytes=$address-$end',
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Referer': 'https://hitomi.la/',
        },
      ).timeout(const Duration(seconds: 4));
      if (res.statusCode == 206 || res.statusCode == 200) {
        final node = decodeBTreeNode(Uint8List.fromList(res.bodyBytes));
        if (node != null) {
          if (_btreeNodeCache.length >= 256) {
            _btreeNodeCache.remove(_btreeNodeCache.keys.first);
          }
          _btreeNodeCache[cacheKey] = node;
        }
        return node;
      }
    } catch (e) {
      Logger.warning('[HitomiNozomi] B-Tree node fetch error ($address): $e');
    }
    return null;
  }

  /// Hitomi 공식 `galleriesindex` B-Tree에서 제목 단어에 매칭되는 갤러리 ID 목록(최신순)을 조회합니다.
  static Future<List<int>> searchTitleWordGalleryIds(
    String term, {
    String language = 'all',
  }) async {
    var clean = term.trim().replaceAll('_', ' ').toLowerCase();
    clean = clean.replaceAll(RegExp(r'''^["']+|["']+$'''), '').trim();
    if (clean.isEmpty) return const <int>[];

    List<int> rawIds;
    if (testTitleWordOverride != null) {
      rawIds = List<int>.from(await testTitleWordOverride!(clean));
    } else {
      final ver = await _getGalleriesIndexVersion();
      if (ver == null || ver.isEmpty) return const <int>[];

      final cacheKey = '$ver:$clean';
      final cached = _titleWordCache.remove(cacheKey);
      if (cached != null) {
        _titleWordCache[cacheKey] = cached;
        rawIds = cached;
      } else {
        rawIds = await _lookupBTreeGalleryIds(ver, clean);
        if (_titleWordCache.length >= 50) {
          _titleWordCache.remove(_titleWordCache.keys.first);
        }
        _titleWordCache[cacheKey] = rawIds;
      }
    }

    if (rawIds.isEmpty) return const <int>[];
    final sorted = List<int>.from(rawIds)..sort((a, b) => b.compareTo(a));

    if (language != 'all' && language.trim().isNotEmpty) {
      final langIds = await fetchAllGalleryIds(getLanguageIndexUrl(language));
      if (langIds.isEmpty) return const <int>[];
      final langSet = langIds.toSet();
      return sorted.where(langSet.contains).toList();
    }
    return sorted;
  }

  static Future<List<int>> _lookupBTreeGalleryIds(
    String version,
    String term,
  ) async {
    final key = hashSearchTerm(term);
    var address = 0;

    for (var depth = 0; depth < 16; depth++) {
      final node = await _getBTreeNode(version, address);
      if (node == null || node.keys.isEmpty) return const <int>[];

      var where = 0;
      var found = false;
      for (var i = 0; i < node.keys.length; i++) {
        final cmp = _compareBytes(key, node.keys[i]);
        if (cmp <= 0) {
          where = i;
          if (cmp == 0) found = true;
          break;
        }
        where = i + 1;
      }

      if (found) {
        if (where >= node.datas.length) return const <int>[];
        final (offset, length) = node.datas[where];
        if (length <= 0 || length > 100000000) return const <int>[];
        try {
          final dataUrl =
              'https://$domain/galleriesindex/galleries.$version.data';
          final res = await http.get(
            dataUrl,
            headers: {
              'Range': 'bytes=$offset-${offset + length - 1}',
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
              'Referer': 'https://hitomi.la/',
            },
          ).timeout(const Duration(seconds: 6));
          if (res.statusCode == 206 || res.statusCode == 200) {
            final bytes = Uint8List.fromList(res.bodyBytes);
            if (bytes.length < 4) return const <int>[];
            final bd = ByteData.sublistView(bytes);
            final count = bd.getInt32(0, Endian.big);
            if (count <= 0 || count > 10000000) return const <int>[];
            final ids = <int>[];
            for (var i = 0; i < count && 4 + (i + 1) * 4 <= bytes.length; i++) {
              ids.add(bd.getInt32(4 + i * 4, Endian.big));
            }
            return ids;
          }
        } catch (e) {
          Logger.warning('[HitomiNozomi] B-Tree data fetch error: $e');
        }
        return const <int>[];
      }

      if (node.isLeaf || where >= node.subnodeAddresses.length) {
        return const <int>[];
      }
      final nextAddr = node.subnodeAddresses[where];
      if (nextAddr == 0) return const <int>[];
      address = nextAddr;
    }
    return const <int>[];
  }
}

class HitomiBTreeNode {
  final List<Uint8List> keys;
  final List<(int offset, int length)> datas;
  final List<int> subnodeAddresses;

  const HitomiBTreeNode({
    required this.keys,
    required this.datas,
    required this.subnodeAddresses,
  });

  bool get isLeaf => subnodeAddresses.every((a) => a == 0);
}
