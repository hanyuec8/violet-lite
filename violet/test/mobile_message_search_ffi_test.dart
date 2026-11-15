// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:violet/component/hitomi/message_corpus_manager.dart';
import 'package:violet/pages/search/message_search_view.dart';
import 'package:violet/settings/settings.dart';
import 'package:violet/src/rust/api/message_search.dart' as rust_msg;
import 'package:violet/src/rust/frb_generated.dart';

void main() {
  late Directory tempDir;

  setUpAll(() async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        'rust/target/debug/rust_lib_violet.dll',
      ),
    );
    tempDir = await Directory.systemTemp.createTemp('violet_fscm_ffi_test_');
  });

  tearDownAll(() async {
    rust_msg.mobileSearchUnload();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('opt-in toggle defaults to false and leaves mobile engine unloaded', () {
    expect(Settings.enableMessageSearch.value, isFalse);
    final prog = rust_msg.mobileSearchProgress();
    expect(prog.initialized, isFalse);
  });

  test('builds Korean FSCM, verifies header, searches with typo & whitelist, and unloads', () async {
    final fscmPath = p.join(tempDir.path, 'merged-ko.fscm');
    final count = await rust_msg.buildFscmFile(
      outputPath: fscmPath,
      entries: [
        rust_msg.FscmBuildEntry(
          articleId: 3001,
          page: 4,
          text: '안녕하세요 반가워요',
          storeRaw: false, // raw 미저장 -> 두벌식 자동 복원 검증
          correctness: 0.96,
          rect: Float32List.fromList([10, 20, 100, 120]),
        ),
        rust_msg.FscmBuildEntry(
          articleId: 3002,
          page: 11,
          text: '오늘은 날씨가 정말 맑고 좋네',
          storeRaw: true,
          correctness: 0.91,
          rect: Float32List.fromList([5, 15, 80, 95]),
        ),
      ],
    );
    expect(count.toInt(), equals(2));

    final info = await rust_msg.verifyFscmFile(path: fscmPath);
    expect(info.recordCount.toInt(), equals(2));

    final initCount = await rust_msg.mobileSearchInit(
      paths: [fscmPath],
      budgetMb: 128,
      searchThreads: 2,
    );
    expect(initCount.toInt(), equals(2));
    expect(rust_msg.mobileSearchProgress().initialized, isTrue);

    // 1. 한글 대사 검색 및 무원문 레코드 한글 복원 확인
    final hits1 = await rust_msg.mobileSearchQuery(
      query: '안녕하세요',
      containsMode: true,
      take: 10,
    );
    expect(hits1, isNotEmpty);
    expect(hits1.first.articleId, equals(3001));
    expect(hits1.first.page, equals(4));
    expect(hits1.first.rawText, equals('안녕하세요반가워요'));
    expect(hits1.first.rect, equals([10.0, 20.0, 100.0, 120.0]));

    // 2. 영타 오타("dkssudgktpdy")로 검색해도 동일 대사 매칭
    final typoHits = await rust_msg.mobileSearchQuery(
      query: 'dkssudgktpdy',
      containsMode: true,
      take: 10,
    );
    expect(typoHits.first.articleId, equals(3001));

    // 3. 작품 조건 화이트리스트 필터링 검증
    final scopedHits = await rust_msg.mobileSearchQuery(
      query: '날씨',
      containsMode: true,
      take: 10,
      filter: rust_msg.MobileSearchFilter(
        whitelistIds: Uint32List.fromList([3002]),
      ),
    );
    expect(scopedHits.length, equals(1));
    expect(scopedHits.first.articleId, equals(3002));
    expect(scopedHits.first.rawText, equals('오늘은 날씨가 정말 맑고 좋네'));

    // 4. 단일 작품 뷰어 내 대사 검색 검증
    final inViewerHits = await rust_msg.mobileSearchArticle(
      articleId: 3002,
      query: '맑고',
    );
    expect(inViewerHits.length, equals(1));
    expect(inViewerHits.first.page, equals(11));

    // 5. 언로드 검증
    expect(rust_msg.mobileSearchUnload(), isTrue);
    expect(rust_msg.mobileSearchProgress().initialized, isFalse);
  });

  test('formats 404 and network errors cleanly without raw Dio stack text', () {
    final req = RequestOptions(path: 'https://example.com/merged-ko.fscm.7z');
    final err404 = DioException(
      requestOptions: req,
      response: Response(requestOptions: req, statusCode: 404),
      type: DioExceptionType.badResponse,
      message: 'This exception was thrown because the response has a status code of 404...',
    );
    final msg404 = MessageCorpusManager.formatDioError(err404);
    expect(msg404, contains('HTTP 404'));
    expect(msg404, isNot(contains('RequestOptions.validateStatus')));

    final errTimeout = DioException(
      requestOptions: req,
      type: DioExceptionType.receiveTimeout,
    );
    expect(
      MessageCorpusManager.formatDioError(errTimeout),
      contains('시간이 초과'),
    );
  });

  test('detects device RAM and auto-selects valid memory budget', () {
    final ramMb = MessageCorpusManager.getDeviceTotalRamMb();
    final budgetMb = MessageCorpusManager.resolveRecommendedBudgetMb();
    expect(ramMb, greaterThan(0));
    expect([128, 256, 512], contains(budgetMb));
  });

  test('returns totalMatched and sorts by latest (4M+) and popular order', () async {
    final fscmPath = p.join(tempDir.path, 'sort_test.fscm');
    final count = await rust_msg.buildFscmFile(
      outputPath: fscmPath,
      entries: [
        rust_msg.FscmBuildEntry(
          articleId: 120000,
          page: 1,
          text: '사랑해 정말로',
          storeRaw: false,
          correctness: 0.95,
          rect: Float32List.fromList([0, 0, 10, 10]),
        ),
        rust_msg.FscmBuildEntry(
          articleId: 4031234,
          page: 5,
          text: '사랑해 정말로',
          storeRaw: false,
          correctness: 0.91,
          rect: Float32List.fromList([0, 0, 10, 10]),
        ),
        rust_msg.FscmBuildEntry(
          articleId: 1951844,
          page: 3,
          text: '사랑해 정말로',
          storeRaw: false,
          correctness: 0.93,
          rect: Float32List.fromList([0, 0, 10, 10]),
        ),
      ],
    );
    expect(count.toInt(), equals(3));

    await rust_msg.mobileSearchInit(
      paths: [fscmPath],
      budgetMb: 128,
      searchThreads: 2,
    );
    expect(rust_msg.mobileSearchProgress().maxArticleId, equals(4031234));
    rust_msg.mobileSearchSetPopularIds(
      ids: Uint32List.fromList([1951844, 120000]),
    );

    final latestRes = await rust_msg.mobileSearchQueryEx(
      query: '사랑해',
      containsMode: true,
      take: 2,
      filter: rust_msg.MobileSearchFilter(
        sortMode: DialogueSortMode.latest.index,
      ),
    );
    expect(latestRes.totalMatched.toInt(), equals(3));
    expect(latestRes.hits.length, equals(2));
    expect(latestRes.hits.first.articleId, equals(4031234));

    final popRes = await rust_msg.mobileSearchQueryEx(
      query: '사랑해',
      containsMode: true,
      take: 2,
      filter: rust_msg.MobileSearchFilter(
        sortMode: DialogueSortMode.popular.index,
      ),
    );
    expect(popRes.totalMatched.toInt(), equals(3));
    expect(popRes.hits.first.articleId, equals(1951844));

    // 드문 대사(정확 일치 < take)에서도 유사도 폴백 없이 정확한 일치 결과만 빠르게 반환
    final relRes = await rust_msg.mobileSearchQueryEx(
      query: '사랑해',
      containsMode: true,
      take: 10,
      filter: rust_msg.MobileSearchFilter(
        sortMode: DialogueSortMode.relevance.index,
      ),
    );
    expect(relRes.totalMatched.toInt(), equals(3));
    expect(relRes.hits.length, equals(3));
  });

  test('computeDialogueOverlayRect maps natural pixel bbox to display rect', () {
    final mapped = computeDialogueOverlayRect(
      rect: [500.0, 400.0, 700.0, 600.0],
      naturalWidth: 1000.0,
      naturalHeight: 1600.0,
      displayWidth: 250.0,
      displayHeight: 400.0,
      padding: 4.0,
    );
    expect(mapped, isNotNull);
    expect(mapped!.left, closeTo(121.0, 0.01));
    expect(mapped.top, closeTo(96.0, 0.01));
    expect(mapped.right, closeTo(179.0, 0.01));
    expect(mapped.bottom, closeTo(154.0, 0.01));

    // [0, 0, 0, 0] 또는 역전된 좌표는 박스를 그리지 않음
    expect(
      computeDialogueOverlayRect(
        rect: [0.0, 0.0, 0.0, 0.0],
        naturalWidth: 1000.0,
        naturalHeight: 1600.0,
        displayWidth: 250.0,
        displayHeight: 400.0,
      ),
      isNull,
    );
  });
}
