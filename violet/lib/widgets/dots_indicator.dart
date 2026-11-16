// This source code is a part of Project Violet.
// Copyright (C) 2020-2024. violet-team. Licensed under the Apache-2.0 License.

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:violet/settings/settings.dart';
import 'package:violet/style/palette.dart';

// https://gist.github.com/collinjackson/4fddbfa2830ea3ac033e34622f278824#file-main-dart-L24
class DotsIndicator extends StatefulWidget {
  const DotsIndicator({
    super.key,
    required this.controller,
    required this.itemCount,
    required this.onPageSelected,
    this.color = Colors.white,
  });

  /// The PageController that this DotsIndicator is representing.
  final PageController controller;

  /// The number of items managed by the PageController
  final int itemCount;

  /// Called when a dot is tapped
  final ValueChanged<int> onPageSelected;

  /// The color of the dots.
  ///
  /// Defaults to `Colors.white`.
  final Color color;

  @override
  State<DotsIndicator> createState() => _DotsIndicatorState();
}

class _DotsIndicatorState extends State<DotsIndicator> {
  // The base size of the dots
  static const double _kDotSize = 6.0;

  // The increase in the size of the selected dot
  static const double _kMaxZoom = 2.0;

  // The distance between the center of each dot
  static const double _kDotSpacing = 20.0;

  // Generous vertical hit target so dots can be tapped reliably
  static const double _kDotTapHeight = 24.0;

  final ScrollController _scrollController = ScrollController();
  int _lastCenteredPage = -1;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onPageControllerChanged);
  }

  @override
  void didUpdateWidget(covariant DotsIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onPageControllerChanged);
      widget.controller.addListener(_onPageControllerChanged);
      _lastCenteredPage = -1;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onPageControllerChanged);
    _scrollController.dispose();
    super.dispose();
  }

  double _currentPage() {
    if (widget.controller.hasClients &&
        widget.controller.positions.length == 1 &&
        widget.controller.position.hasContentDimensions) {
      return widget.controller.page ?? widget.controller.initialPage.toDouble();
    }
    return widget.controller.initialPage.toDouble();
  }

  void _onPageControllerChanged() {
    if (!mounted || widget.itemCount <= 0) return;
    final current = _currentPage().round().clamp(0, widget.itemCount - 1);
    if (current == _lastCenteredPage) return;
    _lastCenteredPage = current;
    _scrollToActiveDot(current);
  }

  void _scrollToActiveDot(int page) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      if (!position.hasContentDimensions || position.maxScrollExtent <= 0) {
        return;
      }

      final dotCenter = page * _kDotSpacing + (_kDotSpacing / 2);
      final target = (dotCenter - (position.viewportDimension / 2)).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );

      if ((position.pixels - target).abs() > 1.0) {
        _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Widget _buildDot(int index, double currentPage) {
    final selectedness = Curves.easeOut.transform(
      max(0.0, 1.0 - (currentPage - index).abs()),
    );
    final zoom = 1.0 + (_kMaxZoom - 1.0) * selectedness;
    final dotColor =
        (Settings.themeWhat.value
                ? Palette.lightThemeBackground
                : Palette.darkThemeBackground)
            .withAlpha((max(zoom - 1, 0.5) * 255).toInt());

    return Material(
      type: MaterialType.transparency,
      child: InkResponse(
        onTap: () => widget.onPageSelected(index),
        radius: _kDotSpacing / 2,
        child: SizedBox(
          width: _kDotSpacing,
          height: _kDotTapHeight,
          child: Center(
            child: Container(
              width: _kDotSize * zoom,
              height: _kDotSize * zoom,
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.itemCount <= 0) {
      return const SizedBox.shrink();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        return AnimatedBuilder(
          animation: widget.controller,
          builder: (context, _) {
            final currentPage = _currentPage();
            final row = Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: List<Widget>.generate(
                widget.itemCount,
                (index) => _buildDot(index, currentPage),
              ),
            );

            final totalWidth = widget.itemCount * _kDotSpacing;
            if (constraints.maxWidth.isFinite &&
                totalWidth > constraints.maxWidth) {
              return SingleChildScrollView(
                controller: _scrollController,
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                child: row,
              );
            }

            return row;
          },
        );
      },
    );
  }
}
