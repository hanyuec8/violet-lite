// This source code is a part of Project Violet.
// Copyright (C) 2020-2024. violet-team. Licensed under the Apache-2.0 License.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:violet/component/image_provider.dart';
import 'package:violet/database/query.dart';
import 'package:violet/util/iter_helper.dart';
import 'package:violet/widgets/article_item/image_provider_manager.dart';
import 'package:violet/widgets/dots_indicator.dart';

typedef IntCallback = Future Function(int);

class PreviewAreaWidget extends StatelessWidget {
  final QueryResult queryResult;
  final IntCallback onPageTapped;

  const PreviewAreaWidget({
    super.key,
    required this.queryResult,
    required this.onPageTapped,
  });

  @override
  Widget build(BuildContext context) {
    var columnLength = 3;

    if (MediaQuery.of(context).orientation == Orientation.landscape) {
      columnLength = 6;
    } else {
      columnLength = 3;
    }

    if (ProviderManager.isExists(queryResult.id())) {
      return FutureBuilder(
        future: Future.value(1).then((value) async {
          VioletImageProvider prov = await ProviderManager.get(
            queryResult.id(),
          );

          return (await prov.getSmallImagesUrl(), await prov.getHeader(0));
        }),
        builder:
            (
              context,
              AsyncSnapshot<(List<String>, Map<String, String>)> snapshot,
            ) {
              if (!snapshot.hasData) {
                return const CircularProgressIndicator();
              }

              final pages = (snapshot.data!.$1)
                  .chunk(30)
                  .map(
                    (chunk) => GridView.count(
                      controller: null,
                      physics: const ScrollPhysics(),
                      shrinkWrap: true,
                      crossAxisCount: columnLength,
                      childAspectRatio: 3 / 4,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                      children: chunk.$2
                          .asMap()
                          .map(
                            (i, e) => MapEntry(
                              i,
                              _buildTappableItem(
                                context,
                                chunk.$1 * 30 + i,
                                e,
                                snapshot.data!.$2,
                              ),
                            ),
                          )
                          .values
                          .toList(),
                    ),
                  )
                  .toList();

              return ExpandablePageView(children: pages);
            },
      );
    }
    return const Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        SizedBox(
          width: 100,
          height: 100,
          child: Align(
            child: Text('??? Unknown Error!', textAlign: TextAlign.center),
          ),
        ),
      ],
    );
  }

  Widget _buildTappableItem(
    BuildContext context,
    int index,
    String image,
    Map<String, String> headers,
  ) {
    return SizedBox.expand(
      child: Stack(
        children: <Widget>[
          SizedBox.expand(
            child: CachedNetworkImage(imageUrl: image, httpHeaders: headers),
          ),
          Align(
            alignment: Alignment.topCenter,
            child: Container(
              padding: const EdgeInsets.only(bottom: 1),
              width: double.infinity,
              color: Colors.black.withOpacity(0.7),
              child: Text(
                '${index + 1} page',
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 11, color: Colors.white),
              ),
            ),
          ),
          Positioned.fill(
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                highlightColor: Colors.transparent,
                onTap: () {
                  onPageTapped(index);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// https://stackoverflow.com/questions/54522980/flutter-adjust-height-of-pageview-horizontal-listview-based-on-current-child
class ExpandablePageView extends StatefulWidget {
  final List<Widget> children;

  const ExpandablePageView({super.key, required this.children});

  @override
  State<ExpandablePageView> createState() => _ExpandablePageViewState();
}

class _ExpandablePageViewState extends State<ExpandablePageView>
    with TickerProviderStateMixin {
  late PageController _pageController;
  late List<double> _heights;
  double _lastMeasuredHeight = 0.0;
  int _currentPage = 0;

  static const _kDuration = Duration(milliseconds: 300);
  static const _kCurve = Curves.ease;
  static const double _kDotsTopPadding = 28.0;

  double get _currentHeight {
    if (_heights.isEmpty) return 0.0;
    final index = _currentPage.clamp(0, _heights.length - 1);
    final height = _heights[index];
    if (height > 0) return height;
    return _lastMeasuredHeight;
  }

  @override
  void initState() {
    _heights = List<double>.filled(widget.children.length, 0.0);
    super.initState();
    _pageController = PageController()
      ..addListener(() {
        if (!mounted || widget.children.isEmpty) return;
        final newPage = (_pageController.page?.round() ?? 0).clamp(
          0,
          widget.children.length - 1,
        );
        if (_currentPage != newPage) {
          setState(() {
            _currentPage = newPage;
          });
          _scrollToPreviewTop();
        }
      });
  }

  @override
  void didUpdateWidget(covariant ExpandablePageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.children.length != oldWidget.children.length) {
      final nextHeights = List<double>.filled(widget.children.length, 0.0);
      for (var i = 0; i < nextHeights.length && i < _heights.length; i++) {
        nextHeights[i] = _heights[i];
      }
      _heights = nextHeights;
      if (_heights.isEmpty) {
        _currentPage = 0;
      } else if (_currentPage >= _heights.length) {
        _currentPage = _heights.length - 1;
      }
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _scrollToPreviewTop() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final scrollable = Scrollable.maybeOf(context);
      final renderObject = context.findRenderObject();
      if (scrollable == null ||
          renderObject == null ||
          !renderObject.attached) {
        return;
      }
      final viewport = RenderAbstractViewport.maybeOf(renderObject);
      if (viewport == null) return;

      final position = scrollable.position;
      final revealOffset = viewport.getOffsetToReveal(renderObject, 0.0).offset;
      final targetOffset = revealOffset.clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );

      final visibleBelowTop =
          position.viewportDimension - (revealOffset - position.pixels);
      if (position.pixels > targetOffset || visibleBelowTop < 160.0) {
        if ((position.pixels - targetOffset).abs() > 1.0) {
          position.animateTo(
            targetOffset,
            duration: _kDuration,
            curve: _kCurve,
          );
        }
      }
    });
  }

  void _selectPage(int page) {
    if (widget.children.isEmpty) return;
    final targetPage = page.clamp(0, widget.children.length - 1);
    if (targetPage == _currentPage) {
      _scrollToPreviewTop();
      return;
    }
    if ((targetPage - _currentPage).abs() > 1) {
      _pageController.jumpToPage(targetPage);
    } else {
      _pageController.animateToPage(
        targetPage,
        duration: _kDuration,
        curve: _kCurve,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.children.isEmpty) {
      return const SizedBox.shrink();
    }

    return TweenAnimationBuilder<double>(
      curve: Curves.easeOutCirc,
      duration: const Duration(milliseconds: 400),
      tween: Tween<double>(begin: _heights[0], end: _currentHeight),
      builder: (context, value, child) => SizedBox(height: value, child: child),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.only(top: _kDotsTopPadding),
            child: PageView(
              controller: _pageController,
              children: _sizeReportingChildren,
            ),
          ),
          Positioned(
            top: 0.0,
            left: 0.0,
            right: 0.0,
            child: Center(
              child: DotsIndicator(
                controller: _pageController,
                itemCount: widget.children.length,
                onPageSelected: _selectPage,
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> get _sizeReportingChildren => widget.children
      .asMap()
      .map(
        (index, child) => MapEntry(
          index,
          OverflowBox(
            //needed, so that parent won't impose its constraints on the children, thus skewing the measurement results.
            minHeight: 0,
            maxHeight: double.infinity,
            alignment: Alignment.topCenter,
            child: SizeReportingWidget(
              onSizeChange: (size) {
                final measuredHeight = size.height + _kDotsTopPadding;
                setState(() {
                  _heights[index] = measuredHeight;
                  if (measuredHeight > 0) {
                    _lastMeasuredHeight = measuredHeight;
                  }
                });
              },
              child: Align(child: child),
            ),
          ),
        ),
      )
      .values
      .toList();
}

class SizeReportingWidget extends StatefulWidget {
  final Widget child;
  final ValueChanged<Size> onSizeChange;

  const SizeReportingWidget({
    super.key,
    required this.child,
    required this.onSizeChange,
  });

  @override
  State<SizeReportingWidget> createState() => _SizeReportingWidgetState();
}

class _SizeReportingWidgetState extends State<SizeReportingWidget> {
  Size? _oldSize;

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _notifySize());
    return widget.child;
  }

  void _notifySize() {
    if (!mounted) {
      return;
    }
    final size = context.size;
    if (_oldSize != size && size != null) {
      _oldSize = size;
      widget.onSizeChange(size);
    }
  }
}
