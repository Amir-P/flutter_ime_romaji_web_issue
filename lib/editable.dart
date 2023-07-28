// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui hide TextStyle;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

export 'package:flutter/services.dart'
    show
        KeyboardInsertedContent,
        SelectionChangedCause,
        SmartDashesType,
        SmartQuotesType,
        TextEditingValue,
        TextInputType,
        TextSelection;

typedef EditableTextContextMenuBuilder = Widget Function(
  BuildContext context,
  EditableTextState editableTextState,
);

const Duration _kCursorBlinkHalfPeriod = Duration(milliseconds: 500);

const List<String> kDefaultContentInsertionMimeTypes = <String>[
  'image/png',
  'image/bmp',
  'image/jpg',
  'image/tiff',
  'image/gif',
  'image/jpeg',
  'image/webp'
];

class _CompositionCallback extends SingleChildRenderObjectWidget {
  const _CompositionCallback(
      {required this.compositeCallback, required this.enabled, super.child});
  final CompositionCallback compositeCallback;
  final bool enabled;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderCompositionCallback(compositeCallback, enabled);
  }

  @override
  void updateRenderObject(
      BuildContext context, _RenderCompositionCallback renderObject) {
    super.updateRenderObject(context, renderObject);
    // _EditableTextState always uses the same callback.
    assert(renderObject.compositeCallback == compositeCallback);
    renderObject.enabled = enabled;
  }
}

class _RenderCompositionCallback extends RenderProxyBox {
  _RenderCompositionCallback(this.compositeCallback, this._enabled);

  final CompositionCallback compositeCallback;
  VoidCallback? _cancelCallback;

  bool get enabled => _enabled;
  bool _enabled = false;
  set enabled(bool newValue) {
    _enabled = newValue;
    if (!newValue) {
      _cancelCallback?.call();
      _cancelCallback = null;
    } else if (_cancelCallback == null) {
      markNeedsPaint();
    }
  }

  @override
  void paint(PaintingContext context, ui.Offset offset) {
    if (enabled) {
      _cancelCallback ??= context.addCompositionCallback(compositeCallback);
    }
    super.paint(context, offset);
  }
}

// A time-value pair that represents a key frame in an animation.
class _KeyFrame {
  const _KeyFrame(this.time, this.value);
  // Values extracted from iOS 15.4 UIKit.
  static const List<_KeyFrame> iOSBlinkingCaretKeyFrames = <_KeyFrame>[
    _KeyFrame(0, 1), // 0
    _KeyFrame(0.5, 1), // 1
    _KeyFrame(0.5375, 0.75), // 2
    _KeyFrame(0.575, 0.5), // 3
    _KeyFrame(0.6125, 0.25), // 4
    _KeyFrame(0.65, 0), // 5
    _KeyFrame(0.85, 0), // 6
    _KeyFrame(0.8875, 0.25), // 7
    _KeyFrame(0.925, 0.5), // 8
    _KeyFrame(0.9625, 0.75), // 9
    _KeyFrame(1, 1), // 10
  ];

  // The timing, in seconds, of the specified animation `value`.
  final double time;
  final double value;
}

class _DiscreteKeyFrameSimulation extends Simulation {
  _DiscreteKeyFrameSimulation.iOSBlinkingCaret()
      : this._(_KeyFrame.iOSBlinkingCaretKeyFrames, 1);
  _DiscreteKeyFrameSimulation._(this._keyFrames, this.maxDuration)
      : assert(_keyFrames.isNotEmpty),
        assert(_keyFrames.last.time <= maxDuration),
        assert(() {
          for (int i = 0; i < _keyFrames.length - 1; i += 1) {
            if (_keyFrames[i].time > _keyFrames[i + 1].time) {
              return false;
            }
          }
          return true;
        }(), 'The key frame sequence must be sorted by time.');

  final double maxDuration;

  final List<_KeyFrame> _keyFrames;

  @override
  double dx(double time) => 0;

  @override
  bool isDone(double time) => time >= maxDuration;

  // The index of the KeyFrame corresponds to the most recent input `time`.
  int _lastKeyFrameIndex = 0;

  @override
  double x(double time) {
    final int length = _keyFrames.length;

    // Perform a linear search in the sorted key frame list, starting from the
    // last key frame found, since the input `time` usually monotonically
    // increases by a small amount.
    int searchIndex;
    final int endIndex;
    if (_keyFrames[_lastKeyFrameIndex].time > time) {
      // The simulation may have restarted. Search within the index range
      // [0, _lastKeyFrameIndex).
      searchIndex = 0;
      endIndex = _lastKeyFrameIndex;
    } else {
      searchIndex = _lastKeyFrameIndex;
      endIndex = length;
    }

    // Find the target key frame. Don't have to check (endIndex - 1): if
    // (endIndex - 2) doesn't work we'll have to pick (endIndex - 1) anyways.
    while (searchIndex < endIndex - 1) {
      assert(_keyFrames[searchIndex].time <= time);
      final _KeyFrame next = _keyFrames[searchIndex + 1];
      if (time < next.time) {
        break;
      }
      searchIndex += 1;
    }

    _lastKeyFrameIndex = searchIndex;
    return _keyFrames[_lastKeyFrameIndex].value;
  }
}

class EditableText extends StatefulWidget {
  EditableText({
    super.key,
    required this.controller,
    required this.focusNode,
    this.readOnly = false,
    this.obscuringCharacter = '•',
    this.obscureText = false,
    this.autocorrect = true,
    SmartDashesType? smartDashesType,
    SmartQuotesType? smartQuotesType,
    this.enableSuggestions = true,
    required this.style,
    StrutStyle? strutStyle,
    required this.cursorColor,
    required this.backgroundCursorColor,
    this.textAlign = TextAlign.start,
    this.maxLines = 1,
    this.minLines,
    this.expands = false,
    this.forceLine = true,
    this.textHeightBehavior,
    this.textWidthBasis = TextWidthBasis.parent,
    this.autofocus = false,
    bool? showCursor,
    this.showSelectionHandles = false,
    this.selectionControls,
    TextInputType? keyboardType,
    this.textCapitalization = TextCapitalization.none,
    this.onEditingComplete,
    this.onSubmitted,
    this.onAppPrivateCommand,
    this.onSelectionChanged,
    this.onTapOutside,
    List<TextInputFormatter>? inputFormatters,
    this.mouseCursor,
    this.rendererIgnoresPointer = false,
    this.cursorWidth = 2.0,
    this.cursorHeight,
    this.cursorRadius,
    this.cursorOpacityAnimates = false,
    this.cursorOffset,
    this.paintCursorAboveText = false,
    this.selectionHeightStyle = ui.BoxHeightStyle.tight,
    this.selectionWidthStyle = ui.BoxWidthStyle.tight,
    this.scrollPadding = const EdgeInsets.all(20.0),
    this.keyboardAppearance = Brightness.light,
    this.dragStartBehavior = DragStartBehavior.start,
    bool? enableInteractiveSelection,
    this.scrollController,
    this.scrollPhysics,
    this.autocorrectionTextRectColor,
    this.autofillHints = const <String>[],
    this.autofillClient,
    this.clipBehavior = Clip.hardEdge,
    this.restorationId,
    this.scrollBehavior,
    this.scribbleEnabled = true,
    this.enableIMEPersonalizedLearning = true,
    this.magnifierConfiguration = TextMagnifierConfiguration.disabled,
    this.undoController,
  })  : assert(obscuringCharacter.length == 1),
        smartDashesType = smartDashesType ??
            (obscureText ? SmartDashesType.disabled : SmartDashesType.enabled),
        smartQuotesType = smartQuotesType ??
            (obscureText ? SmartQuotesType.disabled : SmartQuotesType.enabled),
        assert(minLines == null || minLines > 0),
        assert(
          (maxLines == null) || (minLines == null) || (maxLines >= minLines),
          "minLines can't be greater than maxLines",
        ),
        assert(
          !expands || (maxLines == null && minLines == null),
          'minLines and maxLines must be null when expands is true.',
        ),
        assert(!obscureText || maxLines == 1,
            'Obscured fields cannot be multiline.'),
        enableInteractiveSelection =
            enableInteractiveSelection ?? (!readOnly || !obscureText),
        _strutStyle = strutStyle,
        keyboardType = keyboardType ??
            _inferKeyboardType(
                autofillHints: autofillHints, maxLines: maxLines),
        inputFormatters = maxLines == 1
            ? <TextInputFormatter>[
                FilteringTextInputFormatter.singleLineFormatter,
                ...inputFormatters ??
                    const Iterable<TextInputFormatter>.empty(),
              ]
            : inputFormatters,
        showCursor = showCursor ?? !readOnly;

  /// Controls the text being edited.
  final TextEditingController controller;

  /// Controls whether this widget has keyboard focus.
  final FocusNode focusNode;

  /// {@template flutter.widgets.editableText.obscuringCharacter}
  /// Character used for obscuring text if [obscureText] is true.
  ///
  /// Must be only a single character.
  ///
  /// Defaults to the character U+2022 BULLET (•).
  /// {@endtemplate}
  final String obscuringCharacter;

  /// {@template flutter.widgets.editableText.obscureText}
  /// Whether to hide the text being edited (e.g., for passwords).
  ///
  /// When this is set to true, all the characters in the text field are
  /// replaced by [obscuringCharacter], and the text in the field cannot be
  /// copied with copy or cut. If [readOnly] is also true, then the text cannot
  /// be selected.
  ///
  /// Defaults to false. Cannot be null.
  /// {@endtemplate}
  final bool obscureText;

  /// {@macro dart.ui.textHeightBehavior}
  final TextHeightBehavior? textHeightBehavior;

  /// {@macro flutter.painting.textPainter.textWidthBasis}
  final TextWidthBasis textWidthBasis;

  /// {@template flutter.widgets.editableText.readOnly}
  /// Whether the text can be changed.
  ///
  /// When this is set to true, the text cannot be modified
  /// by any shortcut or keyboard operation. The text is still selectable.
  ///
  /// Defaults to false. Must not be null.
  /// {@endtemplate}
  final bool readOnly;

  /// Whether the text will take the full width regardless of the text width.
  ///
  /// When this is set to false, the width will be based on text width, which
  /// will also be affected by [textWidthBasis].
  ///
  /// Defaults to true. Must not be null.
  ///
  /// See also:
  ///
  ///  * [textWidthBasis], which controls the calculation of text width.
  final bool forceLine;

  /// Whether to show selection handles.
  ///
  /// When a selection is active, there will be two handles at each side of
  /// boundary, or one handle if the selection is collapsed. The handles can be
  /// dragged to adjust the selection.
  ///
  /// See also:
  ///
  ///  * [showCursor], which controls the visibility of the cursor.
  final bool showSelectionHandles;

  /// {@template flutter.widgets.editableText.showCursor}
  /// Whether to show cursor.
  ///
  /// The cursor refers to the blinking caret when the [EditableText] is focused.
  /// {@endtemplate}
  ///
  /// See also:
  ///
  ///  * [showSelectionHandles], which controls the visibility of the selection handles.
  final bool showCursor;

  /// {@template flutter.widgets.editableText.autocorrect}
  /// Whether to enable autocorrection.
  ///
  /// Defaults to true. Cannot be null.
  /// {@endtemplate}
  final bool autocorrect;

  /// {@macro flutter.services.TextInputConfiguration.smartDashesType}
  final SmartDashesType smartDashesType;

  /// {@macro flutter.services.TextInputConfiguration.smartQuotesType}
  final SmartQuotesType smartQuotesType;

  /// {@macro flutter.services.TextInputConfiguration.enableSuggestions}
  final bool enableSuggestions;

  /// The text style to use for the editable text.
  final TextStyle style;

  /// Controls the undo state of the current editable text.
  ///
  /// If null, this widget will create its own [UndoHistoryController].
  final UndoHistoryController? undoController;

  /// {@template flutter.widgets.editableText.strutStyle}
  /// The strut style used for the vertical layout.
  ///
  /// [StrutStyle] is used to establish a predictable vertical layout.
  /// Since fonts may vary depending on user input and due to font
  /// fallback, [StrutStyle.forceStrutHeight] is enabled by default
  /// to lock all lines to the height of the base [TextStyle], provided by
  /// [style]. This ensures the typed text fits within the allotted space.
  ///
  /// If null, the strut used will inherit values from the [style] and will
  /// have [StrutStyle.forceStrutHeight] set to true. When no [style] is
  /// passed, the theme's [TextStyle] will be used to generate [strutStyle]
  /// instead.
  ///
  /// To disable strut-based vertical alignment and allow dynamic vertical
  /// layout based on the glyphs typed, use [StrutStyle.disabled].
  ///
  /// Flutter's strut is based on [typesetting strut](https://en.wikipedia.org/wiki/Strut_(typesetting))
  /// and CSS's [line-height](https://www.w3.org/TR/CSS2/visudet.html#line-height).
  /// {@endtemplate}
  ///
  /// Within editable text and text fields, [StrutStyle] will not use its standalone
  /// default values, and will instead inherit omitted/null properties from the
  /// [TextStyle] instead. See [StrutStyle.inheritFromTextStyle].
  StrutStyle get strutStyle {
    if (_strutStyle == null) {
      return StrutStyle.fromTextStyle(style, forceStrutHeight: true);
    }
    return _strutStyle!.inheritFromTextStyle(style);
  }

  final StrutStyle? _strutStyle;

  /// {@template flutter.widgets.editableText.textAlign}
  /// How the text should be aligned horizontally.
  ///
  /// Defaults to [TextAlign.start] and cannot be null.
  /// {@endtemplate}
  final TextAlign textAlign;

  /// {@template flutter.widgets.editableText.textCapitalization}
  /// Configures how the platform keyboard will select an uppercase or
  /// lowercase keyboard.
  ///
  /// Only supports text keyboards, other keyboard types will ignore this
  /// configuration. Capitalization is locale-aware.
  ///
  /// Defaults to [TextCapitalization.none]. Must not be null.
  ///
  /// See also:
  ///
  ///  * [TextCapitalization], for a description of each capitalization behavior.
  ///
  /// {@endtemplate}
  final TextCapitalization textCapitalization;

  /// The color to use when painting the cursor.
  ///
  /// Cannot be null.
  final Color cursorColor;

  /// The color to use when painting the autocorrection Rect.
  ///
  /// For [CupertinoTextField]s, the value is set to the ambient
  /// [CupertinoThemeData.primaryColor] with 20% opacity. For [TextField]s, the
  /// value is null on non-iOS platforms and the same color used in [CupertinoTextField]
  /// on iOS.
  ///
  /// Currently the autocorrection Rect only appears on iOS.
  ///
  /// Defaults to null, which disables autocorrection Rect painting.
  final Color? autocorrectionTextRectColor;

  /// The color to use when painting the background cursor aligned with the text
  /// while rendering the floating cursor.
  ///
  /// Cannot be null. By default it is the disabled grey color from
  /// CupertinoColors.
  final Color backgroundCursorColor;

  /// {@template flutter.widgets.editableText.maxLines}
  /// The maximum number of lines to show at one time, wrapping if necessary.
  ///
  /// This affects the height of the field itself and does not limit the number
  /// of lines that can be entered into the field.
  ///
  /// If this is 1 (the default), the text will not wrap, but will scroll
  /// horizontally instead.
  ///
  /// If this is null, there is no limit to the number of lines, and the text
  /// container will start with enough vertical space for one line and
  /// automatically grow to accommodate additional lines as they are entered, up
  /// to the height of its constraints.
  ///
  /// If this is not null, the value must be greater than zero, and it will lock
  /// the input to the given number of lines and take up enough horizontal space
  /// to accommodate that number of lines. Setting [minLines] as well allows the
  /// input to grow and shrink between the indicated range.
  ///
  /// The full set of behaviors possible with [minLines] and [maxLines] are as
  /// follows. These examples apply equally to [TextField], [TextFormField],
  /// [CupertinoTextField], and [EditableText].
  ///
  /// Input that occupies a single line and scrolls horizontally as needed.
  /// ```dart
  /// const TextField()
  /// ```
  ///
  /// Input whose height grows from one line up to as many lines as needed for
  /// the text that was entered. If a height limit is imposed by its parent, it
  /// will scroll vertically when its height reaches that limit.
  /// ```dart
  /// const TextField(maxLines: null)
  /// ```
  ///
  /// The input's height is large enough for the given number of lines. If
  /// additional lines are entered the input scrolls vertically.
  /// ```dart
  /// const TextField(maxLines: 2)
  /// ```
  ///
  /// Input whose height grows with content between a min and max. An infinite
  /// max is possible with `maxLines: null`.
  /// ```dart
  /// const TextField(minLines: 2, maxLines: 4)
  /// ```
  ///
  /// See also:
  ///
  ///  * [minLines], which sets the minimum number of lines visible.
  /// {@endtemplate}
  ///  * [expands], which determines whether the field should fill the height of
  ///    its parent.
  final int? maxLines;

  /// {@template flutter.widgets.editableText.minLines}
  /// The minimum number of lines to occupy when the content spans fewer lines.
  ///
  /// This affects the height of the field itself and does not limit the number
  /// of lines that can be entered into the field.
  ///
  /// If this is null (default), text container starts with enough vertical space
  /// for one line and grows to accommodate additional lines as they are entered.
  ///
  /// This can be used in combination with [maxLines] for a varying set of behaviors.
  ///
  /// If the value is set, it must be greater than zero. If the value is greater
  /// than 1, [maxLines] should also be set to either null or greater than
  /// this value.
  ///
  /// When [maxLines] is set as well, the height will grow between the indicated
  /// range of lines. When [maxLines] is null, it will grow as high as needed,
  /// starting from [minLines].
  ///
  /// A few examples of behaviors possible with [minLines] and [maxLines] are as follows.
  /// These apply equally to [TextField], [TextFormField], [CupertinoTextField],
  /// and [EditableText].
  ///
  /// Input that always occupies at least 2 lines and has an infinite max.
  /// Expands vertically as needed.
  /// ```dart
  /// TextField(minLines: 2)
  /// ```
  ///
  /// Input whose height starts from 2 lines and grows up to 4 lines at which
  /// point the height limit is reached. If additional lines are entered it will
  /// scroll vertically.
  /// ```dart
  /// const TextField(minLines:2, maxLines: 4)
  /// ```
  ///
  /// Defaults to null.
  ///
  /// See also:
  ///
  ///  * [maxLines], which sets the maximum number of lines visible, and has
  ///    several examples of how minLines and maxLines interact to produce
  ///    various behaviors.
  /// {@endtemplate}
  ///  * [expands], which determines whether the field should fill the height of
  ///    its parent.
  final int? minLines;

  /// {@template flutter.widgets.editableText.expands}
  /// Whether this widget's height will be sized to fill its parent.
  ///
  /// If set to true and wrapped in a parent widget like [Expanded] or
  /// [SizedBox], the input will expand to fill the parent.
  ///
  /// [maxLines] and [minLines] must both be null when this is set to true,
  /// otherwise an error is thrown.
  ///
  /// Defaults to false.
  ///
  /// See the examples in [maxLines] for the complete picture of how [maxLines],
  /// [minLines], and [expands] interact to produce various behaviors.
  ///
  /// Input that matches the height of its parent:
  /// ```dart
  /// const Expanded(
  ///   child: TextField(maxLines: null, expands: true),
  /// )
  /// ```
  /// {@endtemplate}
  final bool expands;

  /// {@template flutter.widgets.editableText.autofocus}
  /// Whether this text field should focus itself if nothing else is already
  /// focused.
  ///
  /// If true, the keyboard will open as soon as this text field obtains focus.
  /// Otherwise, the keyboard is only shown after the user taps the text field.
  ///
  /// Defaults to false. Cannot be null.
  /// {@endtemplate}
  // See https://github.com/flutter/flutter/issues/7035 for the rationale for this
  // keyboard behavior.
  final bool autofocus;

  /// {@template flutter.widgets.editableText.selectionControls}
  /// Optional delegate for building the text selection handles and toolbar.
  ///
  /// The [EditableText] widget used on its own will not trigger the display
  /// of the selection toolbar by itself. The toolbar is shown by calling
  /// [EditableTextState.showToolbar] in response to an appropriate user event.
  ///
  /// See also:
  ///
  ///  * [CupertinoTextField], which wraps an [EditableText] and which shows the
  ///    selection toolbar upon user events that are appropriate on the iOS
  ///    platform.
  ///  * [TextField], a Material Design themed wrapper of [EditableText], which
  ///    shows the selection toolbar upon appropriate user events based on the
  ///    user's platform set in [ThemeData.platform].
  /// {@endtemplate}
  final TextSelectionControls? selectionControls;

  /// {@template flutter.widgets.editableText.keyboardType}
  /// The type of keyboard to use for editing the text.
  ///
  /// Defaults to [TextInputType.text] if [maxLines] is one and
  /// [TextInputType.multiline] otherwise.
  /// {@endtemplate}
  final TextInputType keyboardType;

  /// {@template flutter.widgets.editableText.onEditingComplete}
  /// Called when the user submits editable content (e.g., user presses the "done"
  /// button on the keyboard).
  ///
  /// The default implementation of [onEditingComplete] executes 2 different
  /// behaviors based on the situation:
  ///
  ///  - When a completion action is pressed, such as "done", "go", "send", or
  ///    "search", the user's content is submitted to the [controller] and then
  ///    focus is given up.
  ///
  ///  - When a non-completion action is pressed, such as "next" or "previous",
  ///    the user's content is submitted to the [controller], but focus is not
  ///    given up because developers may want to immediately move focus to
  ///    another input widget within [onSubmitted].
  ///
  /// Providing [onEditingComplete] prevents the aforementioned default behavior.
  /// {@endtemplate}
  final VoidCallback? onEditingComplete;

  /// {@template flutter.widgets.editableText.onSubmitted}
  /// Called when the user indicates that they are done editing the text in the
  /// field.
  ///
  /// By default, [onSubmitted] is called after [onChanged] when the user
  /// has finalized editing; or, if the default behavior has been overridden,
  /// after [onEditingComplete]. See [onEditingComplete] for details.
  ///
  /// ## Testing
  /// The following is the recommended way to trigger [onSubmitted] in a test:
  ///
  /// ```dart
  /// await tester.testTextInput.receiveAction(TextInputAction.done);
  /// ```
  ///
  /// Sending a `LogicalKeyboardKey.enter` via `tester.sendKeyEvent` will not
  /// trigger [onSubmitted]. This is because on a real device, the engine
  /// translates the enter key to a done action, but `tester.sendKeyEvent` sends
  /// the key to the framework only.
  /// {@endtemplate}
  final ValueChanged<String>? onSubmitted;

  /// {@template flutter.widgets.editableText.onAppPrivateCommand}
  /// This is used to receive a private command from the input method.
  ///
  /// Called when the result of [TextInputClient.performPrivateCommand] is
  /// received.
  ///
  /// This can be used to provide domain-specific features that are only known
  /// between certain input methods and their clients.
  ///
  /// See also:
  ///   * [performPrivateCommand](https://developer.android.com/reference/android/view/inputmethod/InputConnection#performPrivateCommand\(java.lang.String,%20android.os.Bundle\)),
  ///     which is the Android documentation for performPrivateCommand, used to
  ///     send a command from the input method.
  ///   * [sendAppPrivateCommand](https://developer.android.com/reference/android/view/inputmethod/InputMethodManager#sendAppPrivateCommand),
  ///     which is the Android documentation for sendAppPrivateCommand, used to
  ///     send a command to the input method.
  /// {@endtemplate}
  final AppPrivateCommandCallback? onAppPrivateCommand;

  /// {@template flutter.widgets.editableText.onSelectionChanged}
  /// Called when the user changes the selection of text (including the cursor
  /// location).
  /// {@endtemplate}
  final SelectionChangedCallback? onSelectionChanged;

  /// {@template flutter.widgets.editableText.onTapOutside}
  /// Called for each tap that occurs outside of the[TextFieldTapRegion] group
  /// when the text field is focused.
  ///
  /// If this is null, [FocusNode.unfocus] will be called on the [focusNode] for
  /// this text field when a [PointerDownEvent] is received on another part of
  /// the UI. However, it will not unfocus as a result of mobile application
  /// touch events (which does not include mouse clicks), to conform with the
  /// platform conventions. To change this behavior, a callback may be set here
  /// that operates differently from the default.
  ///
  /// When adding additional controls to a text field (for example, a spinner, a
  /// button that copies the selected text, or modifies formatting), it is
  /// helpful if tapping on that control doesn't unfocus the text field. In
  /// order for an external widget to be considered as part of the text field
  /// for the purposes of tapping "outside" of the field, wrap the control in a
  /// [TextFieldTapRegion].
  ///
  /// The [PointerDownEvent] passed to the function is the event that caused the
  /// notification. It is possible that the event may occur outside of the
  /// immediate bounding box defined by the text field, although it will be
  /// within the bounding box of a [TextFieldTapRegion] member.
  /// {@endtemplate}
  ///
  /// {@tool dartpad}
  /// This example shows how to use a `TextFieldTapRegion` to wrap a set of
  /// "spinner" buttons that increment and decrement a value in the [TextField]
  /// without causing the text field to lose keyboard focus.
  ///
  /// This example includes a generic `SpinnerField<T>` class that you can copy
  /// into your own project and customize.
  ///
  /// ** See code in examples/api/lib/widgets/tap_region/text_field_tap_region.0.dart **
  /// {@end-tool}
  ///
  /// See also:
  ///
  ///  * [TapRegion] for how the region group is determined.
  final TapRegionCallback? onTapOutside;

  /// {@template flutter.widgets.editableText.inputFormatters}
  /// Optional input validation and formatting overrides.
  ///
  /// Formatters are run in the provided order when the user changes the text
  /// this widget contains. When this parameter changes, the new formatters will
  /// not be applied until the next time the user inserts or deletes text.
  /// Similar to the [onChanged] callback, formatters don't run when the text is
  /// changed programmatically via [controller].
  ///
  /// See also:
  ///
  ///  * [TextEditingController], which implements the [Listenable] interface
  ///    and notifies its listeners on [TextEditingValue] changes.
  /// {@endtemplate}
  final List<TextInputFormatter>? inputFormatters;

  /// The cursor for a mouse pointer when it enters or is hovering over the
  /// widget.
  ///
  /// If this property is null, [SystemMouseCursors.text] will be used.
  ///
  /// The [mouseCursor] is the only property of [EditableText] that controls the
  /// appearance of the mouse pointer. All other properties related to "cursor"
  /// stands for the text cursor, which is usually a blinking vertical line at
  /// the editing position.
  final MouseCursor? mouseCursor;

  /// If true, the [RenderEditable] created by this widget will not handle
  /// pointer events, see [RenderEditable] and [RenderEditable.ignorePointer].
  ///
  /// This property is false by default.
  final bool rendererIgnoresPointer;

  /// {@template flutter.widgets.editableText.cursorWidth}
  /// How thick the cursor will be.
  ///
  /// Defaults to 2.0.
  ///
  /// The cursor will draw under the text. The cursor width will extend
  /// to the right of the boundary between characters for left-to-right text
  /// and to the left for right-to-left text. This corresponds to extending
  /// downstream relative to the selected position. Negative values may be used
  /// to reverse this behavior.
  /// {@endtemplate}
  final double cursorWidth;

  /// {@template flutter.widgets.editableText.cursorHeight}
  /// How tall the cursor will be.
  ///
  /// If this property is null, [RenderEditable.preferredLineHeight] will be used.
  /// {@endtemplate}
  final double? cursorHeight;

  /// {@template flutter.widgets.editableText.cursorRadius}
  /// How rounded the corners of the cursor should be.
  ///
  /// By default, the cursor has no radius.
  /// {@endtemplate}
  final Radius? cursorRadius;

  /// {@template flutter.widgets.editableText.cursorOpacityAnimates}
  /// Whether the cursor will animate from fully transparent to fully opaque
  /// during each cursor blink.
  ///
  /// By default, the cursor opacity will animate on iOS platforms and will not
  /// animate on Android platforms.
  /// {@endtemplate}
  final bool cursorOpacityAnimates;

  ///{@macro flutter.rendering.RenderEditable.cursorOffset}
  final Offset? cursorOffset;

  ///{@macro flutter.rendering.RenderEditable.paintCursorAboveText}
  final bool paintCursorAboveText;

  /// Controls how tall the selection highlight boxes are computed to be.
  ///
  /// See [ui.BoxHeightStyle] for details on available styles.
  final ui.BoxHeightStyle selectionHeightStyle;

  /// Controls how wide the selection highlight boxes are computed to be.
  ///
  /// See [ui.BoxWidthStyle] for details on available styles.
  final ui.BoxWidthStyle selectionWidthStyle;

  /// The appearance of the keyboard.
  ///
  /// This setting is only honored on iOS devices.
  ///
  /// Defaults to [Brightness.light].
  final Brightness keyboardAppearance;

  /// {@template flutter.widgets.editableText.scrollPadding}
  /// Configures padding to edges surrounding a [Scrollable] when the Textfield scrolls into view.
  ///
  /// When this widget receives focus and is not completely visible (for example scrolled partially
  /// off the screen or overlapped by the keyboard)
  /// then it will attempt to make itself visible by scrolling a surrounding [Scrollable], if one is present.
  /// This value controls how far from the edges of a [Scrollable] the TextField will be positioned after the scroll.
  ///
  /// Defaults to EdgeInsets.all(20.0).
  /// {@endtemplate}
  final EdgeInsets scrollPadding;

  /// {@template flutter.widgets.editableText.enableInteractiveSelection}
  /// Whether to enable user interface affordances for changing the
  /// text selection.
  ///
  /// For example, setting this to true will enable features such as
  /// long-pressing the TextField to select text and show the
  /// cut/copy/paste menu, and tapping to move the text caret.
  ///
  /// When this is false, the text selection cannot be adjusted by
  /// the user, text cannot be copied, and the user cannot paste into
  /// the text field from the clipboard.
  ///
  /// Defaults to true.
  /// {@endtemplate}
  final bool enableInteractiveSelection;

  /// Setting this property to true makes the cursor stop blinking or fading
  /// on and off once the cursor appears on focus. This property is useful for
  /// testing purposes.
  ///
  /// It does not affect the necessity to focus the EditableText for the cursor
  /// to appear in the first place.
  ///
  /// Defaults to false, resulting in a typical blinking cursor.
  static bool debugDeterministicCursor = false;

  /// {@macro flutter.widgets.scrollable.dragStartBehavior}
  final DragStartBehavior dragStartBehavior;

  /// {@template flutter.widgets.editableText.scrollController}
  /// The [ScrollController] to use when vertically scrolling the input.
  ///
  /// If null, it will instantiate a new ScrollController.
  ///
  /// See [Scrollable.controller].
  /// {@endtemplate}
  final ScrollController? scrollController;

  /// {@template flutter.widgets.editableText.scrollPhysics}
  /// The [ScrollPhysics] to use when vertically scrolling the input.
  ///
  /// If not specified, it will behave according to the current platform.
  ///
  /// See [Scrollable.physics].
  /// {@endtemplate}
  ///
  /// If an explicit [ScrollBehavior] is provided to [scrollBehavior], the
  /// [ScrollPhysics] provided by that behavior will take precedence after
  /// [scrollPhysics].
  final ScrollPhysics? scrollPhysics;

  /// {@template flutter.widgets.editableText.scribbleEnabled}
  /// Whether iOS 14 Scribble features are enabled for this widget.
  ///
  /// Only available on iPads.
  ///
  /// Defaults to true.
  /// {@endtemplate}
  final bool scribbleEnabled;

  /// {@template flutter.widgets.editableText.selectionEnabled}
  /// Same as [enableInteractiveSelection].
  ///
  /// This getter exists primarily for consistency with
  /// [RenderEditable.selectionEnabled].
  /// {@endtemplate}
  bool get selectionEnabled => enableInteractiveSelection;

  /// {@template flutter.widgets.editableText.autofillHints}
  /// A list of strings that helps the autofill service identify the type of this
  /// text input.
  ///
  /// When set to null, this text input will not send its autofill information
  /// to the platform, preventing it from participating in autofills triggered
  /// by a different [AutofillClient], even if they're in the same
  /// [AutofillScope]. Additionally, on Android and web, setting this to null
  /// will disable autofill for this text field.
  ///
  /// The minimum platform SDK version that supports Autofill is API level 26
  /// for Android, and iOS 10.0 for iOS.
  ///
  /// Defaults to an empty list.
  ///
  /// ### Setting up iOS autofill:
  ///
  /// To provide the best user experience and ensure your app fully supports
  /// password autofill on iOS, follow these steps:
  ///
  /// * Set up your iOS app's
  ///   [associated domains](https://developer.apple.com/documentation/safariservices/supporting_associated_domains_in_your_app).
  /// * Some autofill hints only work with specific [keyboardType]s. For example,
  ///   [AutofillHints.name] requires [TextInputType.name] and [AutofillHints.email]
  ///   works only with [TextInputType.emailAddress]. Make sure the input field has a
  ///   compatible [keyboardType]. Empirically, [TextInputType.name] works well
  ///   with many autofill hints that are predefined on iOS.
  ///
  /// ### Troubleshooting Autofill
  ///
  /// Autofill service providers rely heavily on [autofillHints]. Make sure the
  /// entries in [autofillHints] are supported by the autofill service currently
  /// in use (the name of the service can typically be found in your mobile
  /// device's system settings).
  ///
  /// #### Autofill UI refuses to show up when I tap on the text field
  ///
  /// Check the device's system settings and make sure autofill is turned on,
  /// and there are available credentials stored in the autofill service.
  ///
  /// * iOS password autofill: Go to Settings -> Password, turn on "Autofill
  ///   Passwords", and add new passwords for testing by pressing the top right
  ///   "+" button. Use an arbitrary "website" if you don't have associated
  ///   domains set up for your app. As long as there's at least one password
  ///   stored, you should be able to see a key-shaped icon in the quick type
  ///   bar on the software keyboard, when a password related field is focused.
  ///
  /// * iOS contact information autofill: iOS seems to pull contact info from
  ///   the Apple ID currently associated with the device. Go to Settings ->
  ///   Apple ID (usually the first entry, or "Sign in to your iPhone" if you
  ///   haven't set up one on the device), and fill out the relevant fields. If
  ///   you wish to test more contact info types, try adding them in Contacts ->
  ///   My Card.
  ///
  /// * Android autofill: Go to Settings -> System -> Languages & input ->
  ///   Autofill service. Enable the autofill service of your choice, and make
  ///   sure there are available credentials associated with your app.
  ///
  /// #### I called `TextInput.finishAutofillContext` but the autofill save
  /// prompt isn't showing
  ///
  /// * iOS: iOS may not show a prompt or any other visual indication when it
  ///   saves user password. Go to Settings -> Password and check if your new
  ///   password is saved. Neither saving password nor auto-generating strong
  ///   password works without properly setting up associated domains in your
  ///   app. To set up associated domains, follow the instructions in
  ///   <https://developer.apple.com/documentation/safariservices/supporting_associated_domains_in_your_app>.
  ///
  /// {@endtemplate}
  /// {@macro flutter.services.AutofillConfiguration.autofillHints}
  final Iterable<String>? autofillHints;

  /// The [AutofillClient] that controls this input field's autofill behavior.
  ///
  /// When null, this widget's [EditableTextState] will be used as the
  /// [AutofillClient]. This property may override [autofillHints].
  final AutofillClient? autofillClient;

  /// {@macro flutter.material.Material.clipBehavior}
  ///
  /// Defaults to [Clip.hardEdge].
  final Clip clipBehavior;

  /// Restoration ID to save and restore the scroll offset of the
  /// [EditableText].
  ///
  /// If a restoration id is provided, the [EditableText] will persist its
  /// current scroll offset and restore it during state restoration.
  ///
  /// The scroll offset is persisted in a [RestorationBucket] claimed from
  /// the surrounding [RestorationScope] using the provided restoration ID.
  ///
  /// Persisting and restoring the content of the [EditableText] is the
  /// responsibility of the owner of the [controller], who may use a
  /// [RestorableTextEditingController] for that purpose.
  ///
  /// See also:
  ///
  ///  * [RestorationManager], which explains how state restoration works in
  ///    Flutter.
  final String? restorationId;

  /// {@template flutter.widgets.shadow.scrollBehavior}
  /// A [ScrollBehavior] that will be applied to this widget individually.
  ///
  /// Defaults to null, wherein the inherited [ScrollBehavior] is copied and
  /// modified to alter the viewport decoration, like [Scrollbar]s.
  /// {@endtemplate}
  ///
  /// [ScrollBehavior]s also provide [ScrollPhysics]. If an explicit
  /// [ScrollPhysics] is provided in [scrollPhysics], it will take precedence,
  /// followed by [scrollBehavior], and then the inherited ancestor
  /// [ScrollBehavior].
  ///
  /// The [ScrollBehavior] of the inherited [ScrollConfiguration] will be
  /// modified by default to only apply a [Scrollbar] if [maxLines] is greater
  /// than 1.
  final ScrollBehavior? scrollBehavior;

  /// {@macro flutter.services.TextInputConfiguration.enableIMEPersonalizedLearning}
  final bool enableIMEPersonalizedLearning;

  /// {@macro flutter.widgets.magnifier.TextMagnifierConfiguration.intro}
  ///
  /// {@macro flutter.widgets.magnifier.intro}
  ///
  /// {@macro flutter.widgets.magnifier.TextMagnifierConfiguration.details}
  final TextMagnifierConfiguration magnifierConfiguration;

  bool get _userSelectionEnabled =>
      enableInteractiveSelection && (!readOnly || !obscureText);

  // Infer the keyboard type of an `EditableText` if it's not specified.
  static TextInputType _inferKeyboardType({
    required Iterable<String>? autofillHints,
    required int? maxLines,
  }) {
    if (autofillHints == null || autofillHints.isEmpty) {
      return maxLines == 1 ? TextInputType.text : TextInputType.multiline;
    }

    final String effectiveHint = autofillHints.first;

    // On iOS oftentimes specifying a text content type is not enough to qualify
    // the input field for autofill. The keyboard type also needs to be compatible
    // with the content type. To get autofill to work by default on EditableText,
    // the keyboard type inference on iOS is done differently from other platforms.
    //
    // The entries with "autofill not working" comments are the iOS text content
    // types that should work with the specified keyboard type but won't trigger
    // (even within a native app). Tested on iOS 13.5.
    if (!kIsWeb) {
      switch (defaultTargetPlatform) {
        case TargetPlatform.iOS:
        case TargetPlatform.macOS:
          const Map<String, TextInputType> iOSKeyboardType =
              <String, TextInputType>{
            AutofillHints.addressCity: TextInputType.name,
            AutofillHints.addressCityAndState:
                TextInputType.name, // Autofill not working.
            AutofillHints.addressState: TextInputType.name,
            AutofillHints.countryName: TextInputType.name,
            AutofillHints.creditCardNumber:
                TextInputType.number, // Couldn't test.
            AutofillHints.email: TextInputType.emailAddress,
            AutofillHints.familyName: TextInputType.name,
            AutofillHints.fullStreetAddress: TextInputType.name,
            AutofillHints.givenName: TextInputType.name,
            AutofillHints.jobTitle: TextInputType.name, // Autofill not working.
            AutofillHints.location: TextInputType.name, // Autofill not working.
            AutofillHints.middleName:
                TextInputType.name, // Autofill not working.
            AutofillHints.name: TextInputType.name,
            AutofillHints.namePrefix:
                TextInputType.name, // Autofill not working.
            AutofillHints.nameSuffix:
                TextInputType.name, // Autofill not working.
            AutofillHints.newPassword: TextInputType.text,
            AutofillHints.newUsername: TextInputType.text,
            AutofillHints.nickname: TextInputType.name, // Autofill not working.
            AutofillHints.oneTimeCode: TextInputType.number,
            AutofillHints.organizationName:
                TextInputType.text, // Autofill not working.
            AutofillHints.password: TextInputType.text,
            AutofillHints.postalCode: TextInputType.name,
            AutofillHints.streetAddressLine1: TextInputType.name,
            AutofillHints.streetAddressLine2:
                TextInputType.name, // Autofill not working.
            AutofillHints.sublocality:
                TextInputType.name, // Autofill not working.
            AutofillHints.telephoneNumber: TextInputType.name,
            AutofillHints.url: TextInputType.url, // Autofill not working.
            AutofillHints.username: TextInputType.text,
          };

          final TextInputType? keyboardType = iOSKeyboardType[effectiveHint];
          if (keyboardType != null) {
            return keyboardType;
          }
        case TargetPlatform.android:
        case TargetPlatform.fuchsia:
        case TargetPlatform.linux:
        case TargetPlatform.windows:
          break;
      }
    }

    if (maxLines != 1) {
      return TextInputType.multiline;
    }

    const Map<String, TextInputType> inferKeyboardType =
        <String, TextInputType>{
      AutofillHints.addressCity: TextInputType.streetAddress,
      AutofillHints.addressCityAndState: TextInputType.streetAddress,
      AutofillHints.addressState: TextInputType.streetAddress,
      AutofillHints.birthday: TextInputType.datetime,
      AutofillHints.birthdayDay: TextInputType.datetime,
      AutofillHints.birthdayMonth: TextInputType.datetime,
      AutofillHints.birthdayYear: TextInputType.datetime,
      AutofillHints.countryCode: TextInputType.number,
      AutofillHints.countryName: TextInputType.text,
      AutofillHints.creditCardExpirationDate: TextInputType.datetime,
      AutofillHints.creditCardExpirationDay: TextInputType.datetime,
      AutofillHints.creditCardExpirationMonth: TextInputType.datetime,
      AutofillHints.creditCardExpirationYear: TextInputType.datetime,
      AutofillHints.creditCardFamilyName: TextInputType.name,
      AutofillHints.creditCardGivenName: TextInputType.name,
      AutofillHints.creditCardMiddleName: TextInputType.name,
      AutofillHints.creditCardName: TextInputType.name,
      AutofillHints.creditCardNumber: TextInputType.number,
      AutofillHints.creditCardSecurityCode: TextInputType.number,
      AutofillHints.creditCardType: TextInputType.text,
      AutofillHints.email: TextInputType.emailAddress,
      AutofillHints.familyName: TextInputType.name,
      AutofillHints.fullStreetAddress: TextInputType.streetAddress,
      AutofillHints.gender: TextInputType.text,
      AutofillHints.givenName: TextInputType.name,
      AutofillHints.impp: TextInputType.url,
      AutofillHints.jobTitle: TextInputType.text,
      AutofillHints.language: TextInputType.text,
      AutofillHints.location: TextInputType.streetAddress,
      AutofillHints.middleInitial: TextInputType.name,
      AutofillHints.middleName: TextInputType.name,
      AutofillHints.name: TextInputType.name,
      AutofillHints.namePrefix: TextInputType.name,
      AutofillHints.nameSuffix: TextInputType.name,
      AutofillHints.newPassword: TextInputType.text,
      AutofillHints.newUsername: TextInputType.text,
      AutofillHints.nickname: TextInputType.text,
      AutofillHints.oneTimeCode: TextInputType.text,
      AutofillHints.organizationName: TextInputType.text,
      AutofillHints.password: TextInputType.text,
      AutofillHints.photo: TextInputType.text,
      AutofillHints.postalAddress: TextInputType.streetAddress,
      AutofillHints.postalAddressExtended: TextInputType.streetAddress,
      AutofillHints.postalAddressExtendedPostalCode: TextInputType.number,
      AutofillHints.postalCode: TextInputType.number,
      AutofillHints.streetAddressLevel1: TextInputType.streetAddress,
      AutofillHints.streetAddressLevel2: TextInputType.streetAddress,
      AutofillHints.streetAddressLevel3: TextInputType.streetAddress,
      AutofillHints.streetAddressLevel4: TextInputType.streetAddress,
      AutofillHints.streetAddressLine1: TextInputType.streetAddress,
      AutofillHints.streetAddressLine2: TextInputType.streetAddress,
      AutofillHints.streetAddressLine3: TextInputType.streetAddress,
      AutofillHints.sublocality: TextInputType.streetAddress,
      AutofillHints.telephoneNumber: TextInputType.phone,
      AutofillHints.telephoneNumberAreaCode: TextInputType.phone,
      AutofillHints.telephoneNumberCountryCode: TextInputType.phone,
      AutofillHints.telephoneNumberDevice: TextInputType.phone,
      AutofillHints.telephoneNumberExtension: TextInputType.phone,
      AutofillHints.telephoneNumberLocal: TextInputType.phone,
      AutofillHints.telephoneNumberLocalPrefix: TextInputType.phone,
      AutofillHints.telephoneNumberLocalSuffix: TextInputType.phone,
      AutofillHints.telephoneNumberNational: TextInputType.phone,
      AutofillHints.transactionAmount:
          TextInputType.numberWithOptions(decimal: true),
      AutofillHints.transactionCurrency: TextInputType.text,
      AutofillHints.url: TextInputType.url,
      AutofillHints.username: TextInputType.text,
    };

    return inferKeyboardType[effectiveHint] ?? TextInputType.text;
  }

  @override
  EditableTextState createState() => EditableTextState();
}

/// State for a [EditableText].
class EditableTextState extends State<EditableText>
    with
        AutomaticKeepAliveClientMixin<EditableText>,
        WidgetsBindingObserver,
        TickerProviderStateMixin<EditableText>,
        TextSelectionDelegate,
        DeltaTextInputClient {
  Timer? _cursorTimer;
  AnimationController get _cursorBlinkOpacityController {
    return _backingCursorBlinkOpacityController ??= AnimationController(
      vsync: this,
    )..addListener(_onCursorColorTick);
  }

  AnimationController? _backingCursorBlinkOpacityController;
  late final Simulation _iosBlinkCursorSimulation =
      _DiscreteKeyFrameSimulation.iOSBlinkingCaret();

  final ValueNotifier<bool> _cursorVisibilityNotifier =
      ValueNotifier<bool>(true);
  final GlobalKey _editableKey = GlobalKey();

  TextInputConnection? _textInputConnection;
  bool get _hasInputConnection => _textInputConnection?.attached ?? false;

  final GlobalKey _scrollableKey = GlobalKey();
  ScrollController? _internalScrollController;
  ScrollController get _scrollController =>
      widget.scrollController ??
      (_internalScrollController ??= ScrollController());

  final LayerLink _toolbarLayerLink = LayerLink();
  final LayerLink _startHandleLayerLink = LayerLink();
  final LayerLink _endHandleLayerLink = LayerLink();

  bool _didAutoFocus = false;

  @override
  AutofillScope? get currentAutofillScope => null;

  late TextStyle _style;

  /// Whether to create an input connection with the platform for text editing
  /// or not.
  ///
  /// Read-only input fields do not need a connection with the platform since
  /// there's no need for text editing capabilities (e.g. virtual keyboard).
  ///
  /// On the web, we always need a connection because we want some browser
  /// functionalities to continue to work on read-only input fields like:
  ///
  /// - Relevant context menu.
  /// - cmd/ctrl+c shortcut to copy.
  /// - cmd/ctrl+a to select all.
  /// - Changing the selection using a physical keyboard.
  bool get _shouldCreateInputConnection => kIsWeb || !widget.readOnly;

  // The time it takes for the floating cursor to snap to the text aligned
  // cursor position after the user has finished placing it.
  static const Duration _floatingCursorResetTime = Duration(milliseconds: 125);

  AnimationController? _floatingCursorResetController;

  Orientation? _lastOrientation;

  @override
  bool get wantKeepAlive => widget.focusNode.hasFocus;

  Color get _cursorColor =>
      widget.cursorColor.withOpacity(_cursorBlinkOpacityController.value);

  @override
  void copySelection(SelectionChangedCause cause) {}

  @override
  void cutSelection(SelectionChangedCause cause) {}

  @override
  Future<void> pasteText(SelectionChangedCause cause) async {}

  @override
  void selectAll(SelectionChangedCause cause) {}

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_didChangeTextEditingValue);
    widget.focusNode.addListener(_handleFocusChanged);
    _cursorVisibilityNotifier.value = widget.showCursor;
  }

  // Whether `TickerMode.of(context)` is true and animations (like blinking the
  // cursor) are supposed to run.
  bool _tickersEnabled = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    _style = MediaQuery.boldTextOf(context)
        ? widget.style.merge(const TextStyle(fontWeight: FontWeight.bold))
        : widget.style;

    if (!_didAutoFocus && widget.autofocus) {
      _didAutoFocus = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted && renderEditable.hasSize) {
          FocusScope.of(context).autofocus(widget.focusNode);
        }
      });
    }

    // Restart or stop the blinking cursor when TickerMode changes.
    final bool newTickerEnabled = TickerMode.of(context);
    if (_tickersEnabled != newTickerEnabled) {
      _tickersEnabled = newTickerEnabled;
      if (_tickersEnabled && _cursorActive) {
        _startCursorBlink();
      } else if (!_tickersEnabled && _cursorTimer != null) {
        // Cannot use _stopCursorBlink because it would reset _cursorActive.
        _cursorTimer!.cancel();
        _cursorTimer = null;
      }
    }

    if (defaultTargetPlatform != TargetPlatform.iOS &&
        defaultTargetPlatform != TargetPlatform.android) {
      return;
    }

    // Hide the text selection toolbar on mobile when orientation changes.
    final Orientation orientation = MediaQuery.orientationOf(context);
    if (_lastOrientation == null) {
      _lastOrientation = orientation;
      return;
    }
    if (orientation != _lastOrientation) {
      _lastOrientation = orientation;
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        hideToolbar(false);
      }
      if (defaultTargetPlatform == TargetPlatform.android) {
        hideToolbar();
      }
    }
  }

  @override
  void didUpdateWidget(EditableText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      oldWidget.controller.removeListener(_didChangeTextEditingValue);
      widget.controller.addListener(_didChangeTextEditingValue);
      _updateRemoteEditingValueIfNeeded();
    }

    if (widget.focusNode != oldWidget.focusNode) {
      oldWidget.focusNode.removeListener(_handleFocusChanged);
      widget.focusNode.addListener(_handleFocusChanged);
      updateKeepAlive();
    }

    if (!_shouldCreateInputConnection) {
      _closeInputConnectionIfNeeded();
    } else if (oldWidget.readOnly && _hasFocus) {
      _openInputConnection();
    }

    if (kIsWeb && _hasInputConnection) {
      if (oldWidget.readOnly != widget.readOnly) {
        _textInputConnection!.updateConfig(textInputConfiguration);
      }
    }

    if (widget.style != oldWidget.style) {
      // The _textInputConnection will pick up the new style when it attaches in
      // _openInputConnection.
      _style = MediaQuery.boldTextOf(context)
          ? widget.style.merge(const TextStyle(fontWeight: FontWeight.bold))
          : widget.style;
      if (_hasInputConnection) {
        _textInputConnection!.setStyle(
          fontFamily: _style.fontFamily,
          fontSize: _style.fontSize,
          fontWeight: _style.fontWeight,
          textDirection: _textDirection,
          textAlign: widget.textAlign,
        );
      }
    }
  }

  @override
  void dispose() {
    _internalScrollController?.dispose();
    widget.controller.removeListener(_didChangeTextEditingValue);
    _floatingCursorResetController?.dispose();
    _floatingCursorResetController = null;
    _closeInputConnectionIfNeeded();
    assert(!_hasInputConnection);
    _cursorTimer?.cancel();
    _cursorTimer = null;
    _backingCursorBlinkOpacityController?.dispose();
    _backingCursorBlinkOpacityController = null;
    widget.focusNode.removeListener(_handleFocusChanged);
    WidgetsBinding.instance.removeObserver(this);
    _cursorVisibilityNotifier.dispose();
    super.dispose();
    assert(_batchEditDepth <= 0, 'unfinished batch edits: $_batchEditDepth');
  }

  // TextInputClient implementation:

  /// The last known [TextEditingValue] of the platform text input plugin.
  ///
  /// This value is updated when the platform text input plugin sends a new
  /// update via [updateEditingValue], or when [EditableText] calls
  /// [TextInputConnection.setEditingState] to overwrite the platform text input
  /// plugin's [TextEditingValue].
  ///
  /// Used in [_updateRemoteEditingValueIfNeeded] to determine whether the
  /// remote value is outdated and needs updating.
  TextEditingValue? _lastKnownRemoteTextEditingValue;

  @override
  TextEditingValue get currentTextEditingValue => _value;

  @override
  void updateEditingValueWithDeltas(List<TextEditingDelta> textEditingDeltas) {
    if (!_shouldCreateInputConnection || textEditingDeltas.isEmpty) return;

    for (final textEditingDelta in textEditingDeltas) {
      int start = 0, end = 0;
      String data = '';
      if (textEditingDelta is TextEditingDeltaInsertion) {
        start = textEditingDelta.insertionOffset;
        data = textEditingDelta.textInserted;
      } else if (textEditingDelta is TextEditingDeltaDeletion) {
        start = textEditingDelta.deletedRange.start;
        end = textEditingDelta.deletedRange.end;
      } else if (textEditingDelta is TextEditingDeltaReplacement) {
        start = textEditingDelta.replacedRange.start;
        end = textEditingDelta.replacedRange.end;
        data = textEditingDelta.replacementText;
      }
      print(
          '${textEditingDelta.runtimeType}: start: $start, end: $end, data: $data');
      _lastKnownRemoteTextEditingValue =
          textEditingDelta.apply(_lastKnownRemoteTextEditingValue!);
      _value = _lastKnownRemoteTextEditingValue!;

      if (data.isNotEmpty) {
        hideToolbar(true);
      }
    }
  }

  @override
  void updateEditingValue(TextEditingValue value) {}

  @override
  void performAction(TextInputAction action) {
    switch (action) {
      case TextInputAction.newline:
        // If this is a multiline EditableText, do nothing for a "newline"
        // action; The newline is already inserted. Otherwise, finalize
        // editing.
        if (!_isMultiline) {
          _finalizeEditing(action, shouldUnfocus: true);
        }
      case TextInputAction.done:
      case TextInputAction.go:
      case TextInputAction.next:
      case TextInputAction.previous:
      case TextInputAction.search:
      case TextInputAction.send:
        _finalizeEditing(action, shouldUnfocus: true);
      case TextInputAction.continueAction:
      case TextInputAction.emergencyCall:
      case TextInputAction.join:
      case TextInputAction.none:
      case TextInputAction.route:
      case TextInputAction.unspecified:
        // Finalize editing, but don't give up focus because this keyboard
        // action does not imply the user is done inputting information.
        _finalizeEditing(action, shouldUnfocus: false);
    }
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {
    widget.onAppPrivateCommand?.call(action, data);
  }

  @override
  void insertContent(KeyboardInsertedContent content) {}

  // The original position of the caret on FloatingCursorDragState.start.
  Rect? _startCaretRect;

  // The most recent text position as determined by the location of the floating
  // cursor.
  TextPosition? _lastTextPosition;

  // The offset of the floating cursor as determined from the start call.
  Offset? _pointOffsetOrigin;

  // The most recent position of the floating cursor.
  Offset? _lastBoundedOffset;

  // Because the center of the cursor is preferredLineHeight / 2 below the touch
  // origin, but the touch origin is used to determine which line the cursor is
  // on, we need this offset to correctly render and move the cursor.
  Offset get _floatingCursorOffset =>
      Offset(0, renderEditable.preferredLineHeight / 2);

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {
    _floatingCursorResetController ??= AnimationController(
      vsync: this,
    )..addListener(_onFloatingCursorResetTick);
    switch (point.state) {
      case FloatingCursorDragState.Start:
        if (_floatingCursorResetController!.isAnimating) {
          _floatingCursorResetController!.stop();
          _onFloatingCursorResetTick();
        }
        // Stop cursor blinking and making it visible.
        _stopCursorBlink(resetCharTicks: false);
        _cursorBlinkOpacityController.value = 1.0;
        // We want to send in points that are centered around a (0,0) origin, so
        // we cache the position.
        _pointOffsetOrigin = point.offset;

        final TextPosition currentTextPosition = TextPosition(
            offset: renderEditable.selection!.baseOffset,
            affinity: renderEditable.selection!.affinity);
        _startCaretRect =
            renderEditable.getLocalRectForCaret(currentTextPosition);

        _lastBoundedOffset = _startCaretRect!.center - _floatingCursorOffset;
        _lastTextPosition = currentTextPosition;
        renderEditable.setFloatingCursor(
            point.state, _lastBoundedOffset!, _lastTextPosition!);
      case FloatingCursorDragState.Update:
        final Offset centeredPoint = point.offset! - _pointOffsetOrigin!;
        final Offset rawCursorOffset =
            _startCaretRect!.center + centeredPoint - _floatingCursorOffset;

        _lastBoundedOffset = renderEditable
            .calculateBoundedFloatingCursorOffset(rawCursorOffset);
        _lastTextPosition = renderEditable.getPositionForPoint(renderEditable
            .localToGlobal(_lastBoundedOffset! + _floatingCursorOffset));
        renderEditable.setFloatingCursor(
            point.state, _lastBoundedOffset!, _lastTextPosition!);
      case FloatingCursorDragState.End:
        // Resume cursor blinking.
        _startCursorBlink();
        // We skip animation if no update has happened.
        if (_lastTextPosition != null && _lastBoundedOffset != null) {
          _floatingCursorResetController!.value = 0.0;
          _floatingCursorResetController!.animateTo(1.0,
              duration: _floatingCursorResetTime, curve: Curves.decelerate);
        }
    }
  }

  void _onFloatingCursorResetTick() {
    final Offset finalPosition =
        renderEditable.getLocalRectForCaret(_lastTextPosition!).centerLeft -
            _floatingCursorOffset;
    if (_floatingCursorResetController!.isCompleted) {
      renderEditable.setFloatingCursor(
          FloatingCursorDragState.End, finalPosition, _lastTextPosition!);
      // Only change if the current selection range is collapsed, to prevent
      // overwriting the result of the iOS keyboard selection gesture.

      _startCaretRect = null;
      _lastTextPosition = null;
      _pointOffsetOrigin = null;
      _lastBoundedOffset = null;
    } else {
      final double lerpValue = _floatingCursorResetController!.value;
      final double lerpX =
          ui.lerpDouble(_lastBoundedOffset!.dx, finalPosition.dx, lerpValue)!;
      final double lerpY =
          ui.lerpDouble(_lastBoundedOffset!.dy, finalPosition.dy, lerpValue)!;

      renderEditable.setFloatingCursor(FloatingCursorDragState.Update,
          Offset(lerpX, lerpY), _lastTextPosition!,
          resetLerpValue: lerpValue);
    }
  }

  @pragma('vm:notify-debugger-on-exception')
  void _finalizeEditing(TextInputAction action, {required bool shouldUnfocus}) {
    // Take any actions necessary now that the user has completed editing.
    if (widget.onEditingComplete != null) {
      try {
        widget.onEditingComplete!();
      } catch (exception, stack) {
        FlutterError.reportError(FlutterErrorDetails(
          exception: exception,
          stack: stack,
          library: 'widgets',
          context:
              ErrorDescription('while calling onEditingComplete for $action'),
        ));
      }
    } else {
      // Default behavior if the developer did not provide an
      // onEditingComplete callback: Finalize editing and remove focus, or move
      // it to the next/previous field, depending on the action.
      widget.controller.clearComposing();
      if (shouldUnfocus) {
        switch (action) {
          case TextInputAction.none:
          case TextInputAction.unspecified:
          case TextInputAction.done:
          case TextInputAction.go:
          case TextInputAction.search:
          case TextInputAction.send:
          case TextInputAction.continueAction:
          case TextInputAction.join:
          case TextInputAction.route:
          case TextInputAction.emergencyCall:
          case TextInputAction.newline:
            widget.focusNode.unfocus();
          case TextInputAction.next:
            widget.focusNode.nextFocus();
          case TextInputAction.previous:
            widget.focusNode.previousFocus();
        }
      }
    }

    final ValueChanged<String>? onSubmitted = widget.onSubmitted;
    if (onSubmitted == null) {
      return;
    }

    // Invoke optional callback with the user's submitted content.
    try {
      onSubmitted(_value.text);
    } catch (exception, stack) {
      FlutterError.reportError(FlutterErrorDetails(
        exception: exception,
        stack: stack,
        library: 'widgets',
        context: ErrorDescription('while calling onSubmitted for $action'),
      ));
    }

    // If `shouldUnfocus` is true, the text field should no longer be focused
    // after the microtask queue is drained. But in case the developer cancelled
    // the focus change in the `onSubmitted` callback by focusing this input
    // field again, reset the soft keyboard.
    // See https://github.com/flutter/flutter/issues/84240.
    //
    // `_restartConnectionIfNeeded` creates a new TextInputConnection to replace
    // the current one. This on iOS switches to a new input view and on Android
    // restarts the input method, and in both cases the soft keyboard will be
    // reset.
    if (shouldUnfocus) {
      _scheduleRestartConnection();
    }
  }

  int _batchEditDepth = 0;

  /// Begins a new batch edit, within which new updates made to the text editing
  /// value will not be sent to the platform text input plugin.
  ///
  /// Batch edits nest. When the outermost batch edit finishes, [endBatchEdit]
  /// will attempt to send [currentTextEditingValue] to the text input plugin if
  /// it detected a change.
  void beginBatchEdit() {
    _batchEditDepth += 1;
  }

  /// Ends the current batch edit started by the last call to [beginBatchEdit],
  /// and send [currentTextEditingValue] to the text input plugin if needed.
  ///
  /// Throws an error in debug mode if this [EditableText] is not in a batch
  /// edit.
  void endBatchEdit() {
    _batchEditDepth -= 1;
    assert(
      _batchEditDepth >= 0,
      'Unbalanced call to endBatchEdit: beginBatchEdit must be called first.',
    );
    _updateRemoteEditingValueIfNeeded();
  }

  void _updateRemoteEditingValueIfNeeded() {
    if (_batchEditDepth > 0 || !_hasInputConnection) {
      return;
    }
    final TextEditingValue localValue = _value;
    if (localValue == _lastKnownRemoteTextEditingValue) {
      return;
    }
    _textInputConnection!.setEditingState(localValue);
    _lastKnownRemoteTextEditingValue = localValue;
  }

  TextEditingValue get _value => widget.controller.value;
  set _value(TextEditingValue value) {
    widget.controller.value = value;
  }

  bool get _hasFocus => widget.focusNode.hasFocus;
  bool get _isMultiline => widget.maxLines != 1;

  // Finds the closest scroll offset to the current scroll offset that fully
  // reveals the given caret rect. If the given rect's main axis extent is too
  // large to be fully revealed in `renderEditable`, it will be centered along
  // the main axis.
  //
  // If this is a multiline EditableText (which means the Editable can only
  // scroll vertically), the given rect's height will first be extended to match
  // `renderEditable.preferredLineHeight`, before the target scroll offset is
  // calculated.
  RevealedOffset _getOffsetToRevealCaret(Rect rect) {
    if (!_scrollController.position.allowImplicitScrolling) {
      return RevealedOffset(offset: _scrollController.offset, rect: rect);
    }

    final Size editableSize = renderEditable.size;
    final double additionalOffset;
    final Offset unitOffset;

    if (!_isMultiline) {
      additionalOffset = rect.width >= editableSize.width
          // Center `rect` if it's oversized.
          ? editableSize.width / 2 - rect.center.dx
          // Valid additional offsets range from (rect.right - size.width)
          // to (rect.left). Pick the closest one if out of range.
          : clampDouble(0.0, rect.right - editableSize.width, rect.left);
      unitOffset = const Offset(1, 0);
    } else {
      // The caret is vertically centered within the line. Expand the caret's
      // height so that it spans the line because we're going to ensure that the
      // entire expanded caret is scrolled into view.
      final Rect expandedRect = Rect.fromCenter(
        center: rect.center,
        width: rect.width,
        height: math.max(rect.height, renderEditable.preferredLineHeight),
      );

      additionalOffset = expandedRect.height >= editableSize.height
          ? editableSize.height / 2 - expandedRect.center.dy
          : clampDouble(
              0.0, expandedRect.bottom - editableSize.height, expandedRect.top);
      unitOffset = const Offset(0, 1);
    }

    // No overscrolling when encountering tall fonts/scripts that extend past
    // the ascent.
    final double targetOffset = clampDouble(
      additionalOffset + _scrollController.offset,
      _scrollController.position.minScrollExtent,
      _scrollController.position.maxScrollExtent,
    );

    final double offsetDelta = _scrollController.offset - targetOffset;
    return RevealedOffset(
        rect: rect.shift(unitOffset * offsetDelta), offset: targetOffset);
  }

  void _openInputConnection() {
    if (!_shouldCreateInputConnection) {
      return;
    }
    if (!_hasInputConnection) {
      final TextEditingValue localValue = _value;

      // When _needsAutofill == true && currentAutofillScope == null, autofill
      // is allowed but saving the user input from the text field is
      // discouraged.
      //
      // In case the autofillScope changes from a non-null value to null, or
      // _needsAutofill changes to false from true, the platform needs to be
      // notified to exclude this field from the autofill context. So we need to
      // provide the autofillId.
      _textInputConnection = TextInput.attach(this, textInputConfiguration);
      _updateSizeAndTransform();
      _schedulePeriodicPostFrameCallbacks();
      _textInputConnection!
        ..setStyle(
          fontFamily: _style.fontFamily,
          fontSize: _style.fontSize,
          fontWeight: _style.fontWeight,
          textDirection: _textDirection,
          textAlign: widget.textAlign,
        )
        ..setEditingState(localValue)
        ..show();
      _lastKnownRemoteTextEditingValue = localValue;
    } else {
      _textInputConnection!.show();
    }
  }

  void _closeInputConnectionIfNeeded() {
    if (_hasInputConnection) {
      _textInputConnection!.close();
      _textInputConnection = null;
      _lastKnownRemoteTextEditingValue = null;
      removeTextPlaceholder();
    }
  }

  void _openOrCloseInputConnectionIfNeeded() {
    if (_hasFocus && widget.focusNode.consumeKeyboardToken()) {
      _openInputConnection();
    } else if (!_hasFocus) {
      _closeInputConnectionIfNeeded();
      widget.controller.clearComposing();
    }
  }

  bool _restartConnectionScheduled = false;
  void _scheduleRestartConnection() {
    if (_restartConnectionScheduled) {
      return;
    }
    _restartConnectionScheduled = true;
    scheduleMicrotask(_restartConnectionIfNeeded);
  }

  // Discards the current [TextInputConnection] and establishes a new one.
  //
  // This method is rarely needed. This is currently used to reset the input
  // type when the "submit" text input action is triggered and the developer
  // puts the focus back to this input field..
  void _restartConnectionIfNeeded() {
    _restartConnectionScheduled = false;
    if (!_hasInputConnection || !_shouldCreateInputConnection) {
      return;
    }
    _textInputConnection!.close();
    _textInputConnection = null;
    _lastKnownRemoteTextEditingValue = null;

    final TextInputConnection newConnection =
        TextInput.attach(this, textInputConfiguration);
    _textInputConnection = newConnection;

    newConnection
      ..show()
      ..setStyle(
        fontFamily: _style.fontFamily,
        fontSize: _style.fontSize,
        fontWeight: _style.fontWeight,
        textDirection: _textDirection,
        textAlign: widget.textAlign,
      )
      ..setEditingState(_value);
    _lastKnownRemoteTextEditingValue = _value;
  }

  @override
  void didChangeInputControl(
      TextInputControl? oldControl, TextInputControl? newControl) {
    if (_hasFocus && _hasInputConnection) {
      oldControl?.hide();
      newControl?.show();
    }
  }

  @override
  void connectionClosed() {
    if (_hasInputConnection) {
      _textInputConnection!.connectionClosedReceived();
      _textInputConnection = null;
      _lastKnownRemoteTextEditingValue = null;
      _finalizeEditing(TextInputAction.done, shouldUnfocus: true);
    }
  }

  /// Express interest in interacting with the keyboard.
  ///
  /// If this control is already attached to the keyboard, this function will
  /// request that the keyboard become visible. Otherwise, this function will
  /// ask the focus system that it become focused. If successful in acquiring
  /// focus, the control will then attach to the keyboard and request that the
  /// keyboard become visible.
  void requestKeyboard() {
    if (_hasFocus) {
      _openInputConnection();
    } else {
      widget.focusNode
          .requestFocus(); // This eventually calls _openInputConnection also, see _handleFocusChanged.
    }
  }

  Rect? _currentCaretRect;

  // Animation configuration for scrolling the caret back on screen.
  static const Duration _caretAnimationDuration = Duration(milliseconds: 100);
  static const Curve _caretAnimationCurve = Curves.fastOutSlowIn;

  bool _showCaretOnScreenScheduled = false;

  void _scheduleShowCaretOnScreen({required bool withAnimation}) {
    if (_showCaretOnScreenScheduled) {
      return;
    }
    _showCaretOnScreenScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((Duration _) {
      _showCaretOnScreenScheduled = false;
      if (_currentCaretRect == null || !_scrollController.hasClients) {
        return;
      }

      // Enlarge the target rect by scrollPadding to ensure that caret is not
      // positioned directly at the edge after scrolling.
      double bottomSpacing = widget.scrollPadding.bottom;

      final EdgeInsets caretPadding =
          widget.scrollPadding.copyWith(bottom: bottomSpacing);

      final RevealedOffset targetOffset =
          _getOffsetToRevealCaret(_currentCaretRect!);

      final Rect rectToReveal;
      final TextSelection selection = textEditingValue.selection;
      if (selection.isCollapsed) {
        rectToReveal = targetOffset.rect;
      } else {
        final List<TextBox> selectionBoxes =
            renderEditable.getBoxesForSelection(selection);
        // selectionBoxes may be empty if, for example, the selection does not
        // encompass a full character, like if it only contained part of an
        // extended grapheme cluster.
        if (selectionBoxes.isEmpty) {
          rectToReveal = targetOffset.rect;
        } else {
          rectToReveal = selection.baseOffset < selection.extentOffset
              ? selectionBoxes.last.toRect()
              : selectionBoxes.first.toRect();
        }
      }

      if (withAnimation) {
        _scrollController.animateTo(
          targetOffset.offset,
          duration: _caretAnimationDuration,
          curve: _caretAnimationCurve,
        );
        renderEditable.showOnScreen(
          rect: caretPadding.inflateRect(rectToReveal),
          duration: _caretAnimationDuration,
          curve: _caretAnimationCurve,
        );
      } else {
        _scrollController.jumpTo(targetOffset.offset);
        renderEditable.showOnScreen(
          rect: caretPadding.inflateRect(rectToReveal),
        );
      }
    });
  }

  late double _lastBottomViewInset;

  @override
  void didChangeMetrics() {
    if (!mounted) {
      return;
    }
    final ui.FlutterView view = View.of(context);
    if (_lastBottomViewInset != view.viewInsets.bottom) {
      if (_lastBottomViewInset < view.viewInsets.bottom) {
        // Because the metrics change signal from engine will come here every frame
        // (on both iOS and Android). So we don't need to show caret with animation.
        _scheduleShowCaretOnScreen(withAnimation: false);
      }
    }
    _lastBottomViewInset = view.viewInsets.bottom;
  }

  @pragma('vm:notify-debugger-on-exception')
  void _formatAndSetValue(TextEditingValue value, SelectionChangedCause? cause,
      {bool userInteraction = false}) {
    final TextEditingValue oldValue = _value;
    final bool textChanged = oldValue.text != value.text;
    final bool textCommitted =
        !oldValue.composing.isCollapsed && value.composing.isCollapsed;
    final bool selectionChanged = oldValue.selection != value.selection;

    if (textChanged || textCommitted) {
      // Only apply input formatters if the text has changed (including uncommitted
      // text in the composing region), or when the user committed the composing
      // text.
      // Gboard is very persistent in restoring the composing region. Applying
      // input formatters on composing-region-only changes (except clearing the
      // current composing region) is very infinite-loop-prone: the formatters
      // will keep trying to modify the composing region while Gboard will keep
      // trying to restore the original composing region.
      try {
        value = widget.inputFormatters?.fold<TextEditingValue>(
              value,
              (TextEditingValue newValue, TextInputFormatter formatter) =>
                  formatter.formatEditUpdate(_value, newValue),
            ) ??
            value;
      } catch (exception, stack) {
        FlutterError.reportError(FlutterErrorDetails(
          exception: exception,
          stack: stack,
          library: 'widgets',
          context: ErrorDescription('while applying input formatters'),
        ));
      }
    }

    final TextSelection oldTextSelection = textEditingValue.selection;

    // Put all optional user callback invocations in a batch edit to prevent
    // sending multiple `TextInput.updateEditingValue` messages.
    beginBatchEdit();
    _value = value;
    // Changes made by the keyboard can sometimes be "out of band" for listening
    // components, so always send those events, even if we didn't think it
    // changed. Also, the user long pressing should always send a selection change
    // as well.
    if (selectionChanged ||
        (userInteraction &&
            (cause == SelectionChangedCause.longPress ||
                cause == SelectionChangedCause.keyboard))) {
      _bringIntoViewBySelectionState(oldTextSelection, value.selection, cause);
    }
    endBatchEdit();
  }

  void _bringIntoViewBySelectionState(TextSelection oldSelection,
      TextSelection newSelection, SelectionChangedCause? cause) {
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        if (cause == SelectionChangedCause.longPress ||
            cause == SelectionChangedCause.drag) {
          bringIntoView(newSelection.extent);
        }
      case TargetPlatform.linux:
      case TargetPlatform.windows:
      case TargetPlatform.fuchsia:
      case TargetPlatform.android:
        if (cause == SelectionChangedCause.drag) {
          if (oldSelection.baseOffset != newSelection.baseOffset) {
            bringIntoView(newSelection.base);
          } else if (oldSelection.extentOffset != newSelection.extentOffset) {
            bringIntoView(newSelection.extent);
          }
        }
    }
  }

  void _onCursorColorTick() {
    renderEditable.cursorColor =
        widget.cursorColor.withOpacity(_cursorBlinkOpacityController.value);
    _cursorVisibilityNotifier.value =
        widget.showCursor && _cursorBlinkOpacityController.value > 0;
  }

  /// Whether the blinking cursor is actually visible at this precise moment
  /// (it's hidden half the time, since it blinks).
  @visibleForTesting
  bool get cursorCurrentlyVisible => _cursorBlinkOpacityController.value > 0;

  /// The cursor blink interval (the amount of time the cursor is in the "on"
  /// state or the "off" state). A complete cursor blink period is twice this
  /// value (half on, half off).
  @visibleForTesting
  Duration get cursorBlinkInterval => _kCursorBlinkHalfPeriod;

  int _obscureShowCharTicksPending = 0;
  int? _obscureLatestCharIndex;

  // Indicates whether the cursor should be blinking right now (but it may
  // actually not blink because it's disabled via TickerMode.of(context)).
  bool _cursorActive = false;

  void _startCursorBlink() {
    assert(!(_cursorTimer?.isActive ?? false) ||
        !(_backingCursorBlinkOpacityController?.isAnimating ?? false));
    _cursorActive = true;
    if (!_tickersEnabled) {
      return;
    }
    _cursorTimer?.cancel();
    _cursorBlinkOpacityController.value = 1.0;
    if (EditableText.debugDeterministicCursor) {
      return;
    }
    if (widget.cursorOpacityAnimates) {
      _cursorBlinkOpacityController
          .animateWith(_iosBlinkCursorSimulation)
          .whenComplete(_onCursorTick);
    } else {
      _cursorTimer = Timer.periodic(_kCursorBlinkHalfPeriod, (Timer timer) {
        _onCursorTick();
      });
    }
  }

  void _onCursorTick() {
    if (_obscureShowCharTicksPending > 0) {
      _obscureShowCharTicksPending =
          WidgetsBinding.instance.platformDispatcher.brieflyShowPassword
              ? _obscureShowCharTicksPending - 1
              : 0;
      if (_obscureShowCharTicksPending == 0) {
        setState(() {});
      }
    }

    if (widget.cursorOpacityAnimates) {
      _cursorTimer?.cancel();
      // Schedule this as an async task to avoid blocking tester.pumpAndSettle
      // indefinitely.
      _cursorTimer = Timer(
          Duration.zero,
          () => _cursorBlinkOpacityController
              .animateWith(_iosBlinkCursorSimulation)
              .whenComplete(_onCursorTick));
    } else {
      if (!(_cursorTimer?.isActive ?? false) && _tickersEnabled) {
        _cursorTimer = Timer.periodic(_kCursorBlinkHalfPeriod, (Timer timer) {
          _onCursorTick();
        });
      }
      _cursorBlinkOpacityController.value =
          _cursorBlinkOpacityController.value == 0 ? 1 : 0;
    }
  }

  void _stopCursorBlink({bool resetCharTicks = true}) {
    _cursorActive = false;
    _cursorBlinkOpacityController.value = 0.0;
    _cursorTimer?.cancel();
    _cursorTimer = null;
    if (resetCharTicks) {
      _obscureShowCharTicksPending = 0;
    }
  }

  void _startOrStopCursorTimerIfNeeded() {
    if (_cursorTimer == null && _hasFocus && _value.selection.isCollapsed) {
      _startCursorBlink();
    } else if (_cursorActive && (!_hasFocus || !_value.selection.isCollapsed)) {
      _stopCursorBlink();
    }
  }

  void _didChangeTextEditingValue() {
    _updateRemoteEditingValueIfNeeded();
    _startOrStopCursorTimerIfNeeded();
    // TODO(abarth): Teach RenderEditable about ValueNotifier<TextEditingValue>
    // to avoid this setState().
    setState(() {/* We use widget.controller.value in build(). */});
  }

  void _handleFocusChanged() {
    _openOrCloseInputConnectionIfNeeded();
    _startOrStopCursorTimerIfNeeded();
    if (_hasFocus) {
      // Listen for changing viewInsets, which indicates keyboard showing up.
      WidgetsBinding.instance.addObserver(this);
      _lastBottomViewInset = View.of(context).viewInsets.bottom;
      if (!widget.readOnly) {
        _scheduleShowCaretOnScreen(withAnimation: true);
      }
    } else {
      WidgetsBinding.instance.removeObserver(this);
      setState(() {
        _currentPromptRectRange = null;
      });
    }
    updateKeepAlive();
  }

  void _compositeCallback(Layer layer) {
    // The callback can be invoked when the layer is detached.
    // The input connection can be closed by the platform in which case this
    // widget doesn't rebuild.
    if (!renderEditable.attached || !_hasInputConnection) {
      return;
    }
    assert(mounted);
    assert((context as Element).debugIsActive);
    _updateSizeAndTransform();
  }

  void _updateSizeAndTransform() {
    final Size size = renderEditable.size;
    final Matrix4 transform = renderEditable.getTransformTo(null);
    _textInputConnection!.setEditableSizeAndTransform(size, transform);
  }

  void _schedulePeriodicPostFrameCallbacks([Duration? duration]) {
    if (!_hasInputConnection) {
      return;
    }
    _updateSelectionRects();
    _updateComposingRectIfNeeded();
    _updateCaretRectIfNeeded();
    SchedulerBinding.instance
        .addPostFrameCallback(_schedulePeriodicPostFrameCallbacks);
  }

  void _updateSelectionRects({bool force = false}) {
    if (!widget.scribbleEnabled ||
        defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }

    final ScrollDirection scrollDirection =
        _scrollController.position.userScrollDirection;
    if (scrollDirection != ScrollDirection.idle) {
      return;
    }

    final InlineSpan inlineSpan = renderEditable.text!;

    final List<SelectionRect> rects = <SelectionRect>[];
    int graphemeStart = 0;
    // Can't use _value.text here: the controller value could change between
    // frames.
    final String plainText =
        inlineSpan.toPlainText(includeSemanticsLabels: false);
    final CharacterRange characterRange = CharacterRange(plainText);
    while (characterRange.moveNext()) {
      final int graphemeEnd = graphemeStart + characterRange.current.length;
      final List<TextBox> boxes = renderEditable.getBoxesForSelection(
        TextSelection(baseOffset: graphemeStart, extentOffset: graphemeEnd),
      );

      final TextBox? box = boxes.isEmpty ? null : boxes.first;
      if (box != null) {
        final Rect paintBounds = renderEditable.paintBounds;
        // Stop early when characters are already below the bottom edge of the
        // RenderEditable, regardless of its clipBehavior.
        if (paintBounds.bottom <= box.top) {
          break;
        }
        if (paintBounds.contains(Offset(box.left, box.top)) ||
            paintBounds.contains(Offset(box.right, box.bottom))) {
          rects.add(SelectionRect(
              position: graphemeStart,
              bounds: box.toRect(),
              direction: box.direction));
        }
      }
      graphemeStart = graphemeEnd;
    }
    _textInputConnection!.setSelectionRects(rects);
  }

  // Sends the current composing rect to the iOS text input plugin via the text
  // input channel. We need to keep sending the information even if no text is
  // currently marked, as the information usually lags behind. The text input
  // plugin needs to estimate the composing rect based on the latest caret rect,
  // when the composing rect info didn't arrive in time.
  void _updateComposingRectIfNeeded() {
    final TextRange composingRange = _value.composing;
    assert(mounted);
    Rect? composingRect =
        renderEditable.getRectForComposingRange(composingRange);
    // Send the caret location instead if there's no marked text yet.
    if (composingRect == null) {
      assert(!composingRange.isValid || composingRange.isCollapsed);
      final int offset = composingRange.isValid ? composingRange.start : 0;
      composingRect =
          renderEditable.getLocalRectForCaret(TextPosition(offset: offset));
    }
    _textInputConnection!.setComposingRect(composingRect);
  }

  void _updateCaretRectIfNeeded() {
    final TextSelection? selection = renderEditable.selection;
    if (selection == null || !selection.isValid || !selection.isCollapsed) {
      return;
    }
    final TextPosition currentTextPosition =
        TextPosition(offset: selection.baseOffset);
    final Rect caretRect =
        renderEditable.getLocalRectForCaret(currentTextPosition);
    _textInputConnection!.setCaretRect(caretRect);
  }

  TextDirection get _textDirection => Directionality.of(context);

  /// The renderer for this widget's descendant.
  ///
  /// This property is typically used to notify the renderer of input gestures
  /// when [RenderEditable.ignorePointer] is true.
  late final RenderEditable renderEditable =
      _editableKey.currentContext!.findRenderObject()! as RenderEditable;

  @override
  TextEditingValue get textEditingValue => _value;

  double get _devicePixelRatio => MediaQuery.devicePixelRatioOf(context);

  @override
  void userUpdateTextEditingValue(
      TextEditingValue value, SelectionChangedCause? cause) {
    // Compare the current TextEditingValue with the pre-format new
    // TextEditingValue value, in case the formatter would reject the change.
    final bool shouldShowCaret =
        widget.readOnly ? _value.selection != value.selection : _value != value;
    if (shouldShowCaret) {
      _scheduleShowCaretOnScreen(withAnimation: true);
    }

    // Even if the value doesn't change, it may be necessary to focus and build
    // the selection overlay. For example, this happens when right clicking an
    // unfocused field that previously had a selection in the same spot.
    if (value == textEditingValue) {
      if (!widget.focusNode.hasFocus) {
        widget.focusNode.requestFocus();
      }
      return;
    }

    _formatAndSetValue(value, cause, userInteraction: true);
  }

  @override
  void bringIntoView(TextPosition position) {
    final Rect localRect = renderEditable.getLocalRectForCaret(position);
    final RevealedOffset targetOffset = _getOffsetToRevealCaret(localRect);

    _scrollController.jumpTo(targetOffset.offset);
    renderEditable.showOnScreen(rect: targetOffset.rect);
  }

  @override
  bool showToolbar() => true;

  @override
  void hideToolbar([bool hideHandles = true]) {}

  @override
  void insertTextPlaceholder(Size size) {}

  @override
  void removeTextPlaceholder() {}

  @override
  void performSelector(String selectorName) {
    final Intent? intent = intentForMacOSSelector(selectorName);

    if (intent != null) {
      final BuildContext? primaryContext = primaryFocus?.context;
      if (primaryContext != null) {
        Actions.invoke(primaryContext, intent);
      }
    }
  }

  TextInputConfiguration get textInputConfiguration => TextInputConfiguration(
        enableDeltaModel: true,
        inputType: widget.keyboardType,
        readOnly: widget.readOnly,
        obscureText: widget.obscureText,
        autocorrect: widget.autocorrect,
        smartDashesType: widget.smartDashesType,
        smartQuotesType: widget.smartQuotesType,
        enableSuggestions: widget.enableSuggestions,
        enableInteractiveSelection: widget._userSelectionEnabled,
        textCapitalization: widget.textCapitalization,
        keyboardAppearance: widget.keyboardAppearance,
        enableIMEPersonalizedLearning: widget.enableIMEPersonalizedLearning,
      );

  // null if no promptRect should be shown.
  TextRange? _currentPromptRectRange;

  @override
  void showAutocorrectionPromptRect(int start, int end) {
    setState(() {
      _currentPromptRectRange = TextRange(start: start, end: end);
    });
  }

  /// The default behavior used if [onTapOutside] is null.
  ///
  /// The `event` argument is the [PointerDownEvent] that caused the notification.
  void _defaultOnTapOutside(PointerDownEvent event) {
    /// The focus dropping behavior is only present on desktop platforms
    /// and mobile browsers.
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        // On mobile platforms, we don't unfocus on touch events unless they're
        // in the web browser, but we do unfocus for all other kinds of events.
        switch (event.kind) {
          case ui.PointerDeviceKind.touch:
            if (kIsWeb) {
              widget.focusNode.unfocus();
            }
          case ui.PointerDeviceKind.mouse:
          case ui.PointerDeviceKind.stylus:
          case ui.PointerDeviceKind.invertedStylus:
          case ui.PointerDeviceKind.unknown:
            widget.focusNode.unfocus();
          case ui.PointerDeviceKind.trackpad:
            throw UnimplementedError(
                'Unexpected pointer down event for trackpad');
        }
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        widget.focusNode.unfocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    assert(debugCheckHasMediaQuery(context));
    super.build(context); // See AutomaticKeepAliveClientMixin.

    return _CompositionCallback(
      compositeCallback: _compositeCallback,
      enabled: _hasInputConnection,
      child: TextFieldTapRegion(
        onTapOutside: widget.onTapOutside ?? _defaultOnTapOutside,
        debugLabel: kReleaseMode ? null : 'EditableText',
        child: MouseRegion(
          cursor: widget.mouseCursor ?? SystemMouseCursors.text,
          child: UndoHistory<TextEditingValue>(
            value: widget.controller,
            onTriggered: (TextEditingValue value) {
              userUpdateTextEditingValue(value, SelectionChangedCause.keyboard);
            },
            shouldChangeUndoStack:
                (TextEditingValue? oldValue, TextEditingValue newValue) {
              if (!newValue.selection.isValid) {
                return false;
              }

              if (oldValue == null) {
                return true;
              }

              switch (defaultTargetPlatform) {
                case TargetPlatform.iOS:
                case TargetPlatform.macOS:
                case TargetPlatform.fuchsia:
                case TargetPlatform.linux:
                case TargetPlatform.windows:
                  // Composing text is not counted in history coalescing.
                  if (!widget.controller.value.composing.isCollapsed) {
                    return false;
                  }
                case TargetPlatform.android:
                  // Gboard on Android puts non-CJK words in composing regions. Coalesce
                  // composing text in order to allow the saving of partial words in that
                  // case.
                  break;
              }

              return oldValue.text != newValue.text ||
                  oldValue.composing != newValue.composing;
            },
            focusNode: widget.focusNode,
            controller: widget.undoController,
            child: Focus(
              focusNode: widget.focusNode,
              includeSemantics: false,
              debugLabel: kReleaseMode ? null : 'EditableText',
              child: Scrollable(
                key: _scrollableKey,
                excludeFromSemantics: true,
                axisDirection:
                    _isMultiline ? AxisDirection.down : AxisDirection.right,
                controller: _scrollController,
                physics: widget.scrollPhysics,
                dragStartBehavior: widget.dragStartBehavior,
                restorationId: widget.restorationId,
                // If a ScrollBehavior is not provided, only apply scrollbars when
                // multiline. The overscroll indicator should not be applied in
                // either case, glowing or stretching.
                scrollBehavior: widget.scrollBehavior ??
                    ScrollConfiguration.of(context).copyWith(
                      scrollbars: _isMultiline,
                      overscroll: false,
                    ),
                viewportBuilder: (BuildContext context, ViewportOffset offset) {
                  return CompositedTransformTarget(
                    link: _toolbarLayerLink,
                    child: _Editable(
                      key: _editableKey,
                      startHandleLayerLink: _startHandleLayerLink,
                      endHandleLayerLink: _endHandleLayerLink,
                      inlineSpan: buildTextSpan(),
                      value: _value,
                      cursorColor: _cursorColor,
                      backgroundCursorColor: widget.backgroundCursorColor,
                      showCursor: EditableText.debugDeterministicCursor
                          ? ValueNotifier<bool>(widget.showCursor)
                          : _cursorVisibilityNotifier,
                      forceLine: widget.forceLine,
                      readOnly: widget.readOnly,
                      hasFocus: _hasFocus,
                      maxLines: widget.maxLines,
                      minLines: widget.minLines,
                      expands: widget.expands,
                      strutStyle: widget.strutStyle,
                      textScaleFactor: MediaQuery.textScaleFactorOf(context),
                      textAlign: widget.textAlign,
                      textDirection: _textDirection,
                      textHeightBehavior: widget.textHeightBehavior ??
                          DefaultTextHeightBehavior.maybeOf(context),
                      textWidthBasis: widget.textWidthBasis,
                      obscuringCharacter: widget.obscuringCharacter,
                      obscureText: widget.obscureText,
                      offset: offset,
                      rendererIgnoresPointer: widget.rendererIgnoresPointer,
                      cursorWidth: widget.cursorWidth,
                      cursorHeight: widget.cursorHeight,
                      cursorRadius: widget.cursorRadius,
                      cursorOffset: widget.cursorOffset ?? Offset.zero,
                      selectionHeightStyle: widget.selectionHeightStyle,
                      selectionWidthStyle: widget.selectionWidthStyle,
                      paintCursorAboveText: widget.paintCursorAboveText,
                      enableInteractiveSelection: widget._userSelectionEnabled,
                      textSelectionDelegate: this,
                      devicePixelRatio: _devicePixelRatio,
                      promptRectRange: _currentPromptRectRange,
                      promptRectColor: widget.autocorrectionTextRectColor,
                      clipBehavior: widget.clipBehavior,
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Builds [TextSpan] from current editing value.
  ///
  /// By default makes text in composing range appear as underlined.
  /// Descendants can override this method to customize appearance of text.
  TextSpan buildTextSpan() {
    if (widget.obscureText) {
      String text = _value.text;
      text = widget.obscuringCharacter * text.length;
      // Reveal the latest character in an obscured field only on mobile.
      // Newer versions of iOS (iOS 15+) no longer reveal the most recently
      // entered character.
      const Set<TargetPlatform> mobilePlatforms = <TargetPlatform>{
        TargetPlatform.android,
        TargetPlatform.fuchsia,
      };
      final bool brieflyShowPassword =
          WidgetsBinding.instance.platformDispatcher.brieflyShowPassword &&
              mobilePlatforms.contains(defaultTargetPlatform);
      if (brieflyShowPassword) {
        final int? o =
            _obscureShowCharTicksPending > 0 ? _obscureLatestCharIndex : null;
        if (o != null && o >= 0 && o < text.length) {
          text = text.replaceRange(o, o + 1, _value.text.substring(o, o + 1));
        }
      }
      return TextSpan(style: _style, text: text);
    }
    final bool withComposing = !widget.readOnly && _hasFocus;

    // Read only mode should not paint text composing.
    return widget.controller.buildTextSpan(
      context: context,
      style: _style,
      withComposing: withComposing,
    );
  }
}

class _Editable extends MultiChildRenderObjectWidget {
  _Editable({
    super.key,
    required this.inlineSpan,
    required this.value,
    required this.startHandleLayerLink,
    required this.endHandleLayerLink,
    this.cursorColor,
    this.backgroundCursorColor,
    required this.showCursor,
    required this.forceLine,
    required this.readOnly,
    this.textHeightBehavior,
    required this.textWidthBasis,
    required this.hasFocus,
    required this.maxLines,
    this.minLines,
    required this.expands,
    this.strutStyle,
    required this.textScaleFactor,
    required this.textAlign,
    required this.textDirection,
    required this.obscuringCharacter,
    required this.obscureText,
    required this.offset,
    this.rendererIgnoresPointer = false,
    required this.cursorWidth,
    this.cursorHeight,
    this.cursorRadius,
    required this.cursorOffset,
    required this.paintCursorAboveText,
    this.selectionHeightStyle = ui.BoxHeightStyle.tight,
    this.selectionWidthStyle = ui.BoxWidthStyle.tight,
    this.enableInteractiveSelection = true,
    required this.textSelectionDelegate,
    required this.devicePixelRatio,
    this.promptRectRange,
    this.promptRectColor,
    required this.clipBehavior,
  }) : super(children: _extractChildren(inlineSpan));

  // Traverses the InlineSpan tree and depth-first collects the list of
  // child widgets that are created in WidgetSpans.
  static List<Widget> _extractChildren(InlineSpan span) {
    final List<Widget> result = <Widget>[];
    span.visitChildren((InlineSpan span) {
      if (span is WidgetSpan) {
        result.add(span.child);
      }
      return true;
    });
    return result;
  }

  final InlineSpan inlineSpan;
  final TextEditingValue value;
  final Color? cursorColor;
  final LayerLink startHandleLayerLink;
  final LayerLink endHandleLayerLink;
  final Color? backgroundCursorColor;
  final ValueNotifier<bool> showCursor;
  final bool forceLine;
  final bool readOnly;
  final bool hasFocus;
  final int? maxLines;
  final int? minLines;
  final bool expands;
  final StrutStyle? strutStyle;
  final double textScaleFactor;
  final TextAlign textAlign;
  final TextDirection textDirection;
  final String obscuringCharacter;
  final bool obscureText;
  final TextHeightBehavior? textHeightBehavior;
  final TextWidthBasis textWidthBasis;
  final ViewportOffset offset;
  final bool rendererIgnoresPointer;
  final double cursorWidth;
  final double? cursorHeight;
  final Radius? cursorRadius;
  final Offset cursorOffset;
  final bool paintCursorAboveText;
  final ui.BoxHeightStyle selectionHeightStyle;
  final ui.BoxWidthStyle selectionWidthStyle;
  final bool enableInteractiveSelection;
  final TextSelectionDelegate textSelectionDelegate;
  final double devicePixelRatio;
  final TextRange? promptRectRange;
  final Color? promptRectColor;
  final Clip clipBehavior;

  @override
  RenderEditable createRenderObject(BuildContext context) {
    return RenderEditable(
      text: inlineSpan,
      cursorColor: cursorColor,
      startHandleLayerLink: startHandleLayerLink,
      endHandleLayerLink: endHandleLayerLink,
      backgroundCursorColor: backgroundCursorColor,
      showCursor: showCursor,
      forceLine: forceLine,
      readOnly: readOnly,
      hasFocus: hasFocus,
      maxLines: maxLines,
      minLines: minLines,
      expands: expands,
      strutStyle: strutStyle,
      textAlign: textAlign,
      textDirection: textDirection,
      selection: value.selection,
      offset: offset,
      ignorePointer: rendererIgnoresPointer,
      obscuringCharacter: obscuringCharacter,
      obscureText: obscureText,
      textHeightBehavior: textHeightBehavior,
      textWidthBasis: textWidthBasis,
      cursorWidth: cursorWidth,
      cursorHeight: cursorHeight,
      cursorRadius: cursorRadius,
      cursorOffset: cursorOffset,
      paintCursorAboveText: paintCursorAboveText,
      selectionHeightStyle: selectionHeightStyle,
      selectionWidthStyle: selectionWidthStyle,
      enableInteractiveSelection: enableInteractiveSelection,
      textSelectionDelegate: textSelectionDelegate,
      devicePixelRatio: devicePixelRatio,
      promptRectRange: promptRectRange,
      promptRectColor: promptRectColor,
      clipBehavior: clipBehavior,
    );
  }

  @override
  void updateRenderObject(BuildContext context, RenderEditable renderObject) {
    renderObject
      ..text = inlineSpan
      ..cursorColor = cursorColor
      ..startHandleLayerLink = startHandleLayerLink
      ..endHandleLayerLink = endHandleLayerLink
      ..backgroundCursorColor = backgroundCursorColor
      ..showCursor = showCursor
      ..forceLine = forceLine
      ..readOnly = readOnly
      ..hasFocus = hasFocus
      ..maxLines = maxLines
      ..minLines = minLines
      ..expands = expands
      ..strutStyle = strutStyle
      ..textAlign = textAlign
      ..textDirection = textDirection
      ..selection = value.selection
      ..offset = offset
      ..ignorePointer = rendererIgnoresPointer
      ..textHeightBehavior = textHeightBehavior
      ..textWidthBasis = textWidthBasis
      ..obscuringCharacter = obscuringCharacter
      ..obscureText = obscureText
      ..cursorWidth = cursorWidth
      ..cursorHeight = cursorHeight
      ..cursorRadius = cursorRadius
      ..cursorOffset = cursorOffset
      ..selectionHeightStyle = selectionHeightStyle
      ..selectionWidthStyle = selectionWidthStyle
      ..enableInteractiveSelection = enableInteractiveSelection
      ..textSelectionDelegate = textSelectionDelegate
      ..devicePixelRatio = devicePixelRatio
      ..paintCursorAboveText = paintCursorAboveText
      ..promptRectColor = promptRectColor
      ..clipBehavior = clipBehavior
      ..setPromptRectRange(promptRectRange);
  }
}
