import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as parser;

import 'image_properties.dart';

typedef CustomRender = Widget Function(dom.Node node, List<Widget> children);
typedef CustomTextStyle = TextStyle Function(
  dom.Node node,
  TextStyle? baseStyle,
);
typedef CustomTextAlign = TextAlign? Function(dom.Element elem);
typedef CustomEdgeInsets = EdgeInsets Function(dom.Node node);
typedef OnLinkTap = void Function(String url);
typedef OnImageTap = void Function(String source);

const double OFFSET_TAGS_FONT_SIZE_FACTOR =
    0.7; //The ratio of the parent font for each of the offset tags: sup or sub

class LinkTextSpan extends TextSpan {
  // Beware!
  //
  // This class is only safe because the TapGestureRecognizer is not
  // given a deadline and therefore never allocates any resources.
  //
  // In any other situation -- setting a deadline, using any of the less trivial
  // recognizers, etc -- you would have to manage the gesture recognizer's
  // lifetime and call dispose() when the TextSpan was no longer being rendered.
  //
  // Since TextSpan itself is @immutable, this means that you would have to
  // manage the recognizer from outside the TextSpan, e.g. in the State of a
  // stateful widget that then hands the recognizer to the TextSpan.
  final String? url;

  LinkTextSpan(
      {TextStyle? style,
      this.url,
      String? text,
      OnLinkTap? onLinkTap,
      List<TextSpan>? children})
      : super(
          style: style,
          text: text,
          children: children ?? <TextSpan>[],
          recognizer: TapGestureRecognizer()
            ..onTap = () {
              onLinkTap?.call(url ?? '');
            },
        );
}

class LinkBlock extends Container {
  // final String url;
  // final EdgeInsets padding;
  // final EdgeInsets margin;
  // final OnLinkTap onLinkTap;
  final List<Widget>? children;

  LinkBlock({
    String? url,
    EdgeInsets? padding,
    EdgeInsets? margin,
    OnLinkTap? onLinkTap,
    this.children,
  }) : super(
          padding: padding,
          margin: margin,
          child: GestureDetector(
            onTap: () {
              if (onLinkTap != null) {
                onLinkTap(url ?? '');
              }
            },
            child: Column(
              children: <Widget>[...?children],
            ),
          ),
        );
}

class BlockText extends StatelessWidget {
  final RichText child;
  final EdgeInsets? padding;
  final EdgeInsets? margin;
  final Decoration? decoration;
  final bool shrinkToFit;

  const BlockText({
    required this.child,
    required this.shrinkToFit,
    this.padding,
    this.margin,
    this.decoration,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: shrinkToFit ? null : double.infinity,
      padding: padding,
      margin: margin,
      decoration: decoration,
      child: child,
    );
  }
}

class ParseContext {
  List<Widget>? rootWidgetList; // the widgetList accumulator
  dynamic parentElement; // the parent spans accumulator
  int indentLevel = 0;
  int listCount = 0;
  String listChar = '•';
  String? blockType; // blockType can be 'p', 'div', 'ul', 'ol', 'blockquote'
  bool condenseWhitespace = true;
  bool spansOnly = false;
  bool inBlock = false;
  TextStyle? childStyle;

  ParseContext({
    this.rootWidgetList,
    this.parentElement,
    this.indentLevel = 0,
    this.listCount = 0,
    this.listChar = '•',
    this.blockType,
    this.condenseWhitespace = true,
    this.spansOnly = false,
    this.inBlock = false,
    this.childStyle,
  }) {
    childStyle = childStyle ?? const TextStyle();
  }

  ParseContext.fromContext(ParseContext parseContext) {
    rootWidgetList = parseContext.rootWidgetList;
    parentElement = parseContext.parentElement;
    indentLevel = parseContext.indentLevel;
    listCount = parseContext.listCount;
    listChar = parseContext.listChar;
    blockType = parseContext.blockType;
    condenseWhitespace = parseContext.condenseWhitespace;
    spansOnly = parseContext.spansOnly;
    inBlock = parseContext.inBlock;
    childStyle = parseContext.childStyle ?? const TextStyle();
  }
}

class HtmlRichTextParser extends StatelessWidget {
  HtmlRichTextParser({
    this.shrinkToFit,
    this.onLinkTap,
    this.renderNewlines = false,
    this.html,
    this.customEdgeInsets,
    this.customTextStyle,
    this.customTextAlign,
    this.onImageError,
    this.linkStyle = const TextStyle(
      decoration: TextDecoration.underline,
      color: Colors.blueAccent,
      decorationColor: Colors.blueAccent,
    ),
    this.imageProperties,
    this.onImageTap,
    this.showImages = true,
    this.textMatcher,
    this.textReplaceFunction,
  });

  final double indentSize = 10;

  final bool? shrinkToFit;
  final onLinkTap;
  final bool renderNewlines;
  final String? html;
  final CustomEdgeInsets? customEdgeInsets;
  final CustomTextStyle? customTextStyle;
  final CustomTextAlign? customTextAlign;
  final ImageErrorListener? onImageError;
  final TextStyle linkStyle;
  final ImageProperties? imageProperties;
  final OnImageTap? onImageTap;
  final bool showImages;
  final RegExp? textMatcher;
  final Widget Function(String fullmatch, List<String?> groups)?
      textReplaceFunction;

  // style elements set a default style
  // for all child nodes
  // treat ol, ul, and blockquote like style elements also
  static const List<String> _supportedStyleElements = <String>[
    "b",
    "i",
    "address",
    "cite",
    "var",
    "em",
    "strong",
    "kbd",
    "samp",
    "tt",
    "code",
    "ins",
    "u",
    "small",
    "abbr",
    "acronym",
    "mark",
    "ol",
    "ul",
    "blockquote",
    "del",
    "s",
    "strike",
    "ruby",
    "rp",
    "rt",
    "bdi",
    "data",
    "time",
    "span",
    "big",
    "sub",
  ];

  // specialty elements require unique handling
  // eg. the "a" tag can contain a block of text or an image
  // sometimes "a" will be rendered with a textspan and recognizer
  // sometimes "a" will be rendered with a clickable Block
  static const List<String> _supportedSpecialtyElements = <String>[
    "a",
    "br",
    "table",
    "tbody",
    "caption",
    "td",
    "tfoot",
    "th",
    "thead",
    "tr",
    "q",
  ];

  // block elements are always rendered with a new
  // block-level widget, if a block level element
  // is found inside another block level element,
  // we simply treat it as a new block level element
  static const List<String> _supportedBlockElements = <String>[
    "article",
    "aside",
    "body",
    "center",
    "dd",
    "dfn",
    "div",
    "dl",
    "dt",
    "figcaption",
    "figure",
    "footer",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "header",
    "hr",
    "img",
    "li",
    "main",
    "nav",
    "noscript",
    "p",
    "pre",
    "section",
  ];

  static List<String> get _supportedElements => <String>[]
    ..addAll(_supportedStyleElements)
    ..addAll(_supportedSpecialtyElements)
    ..addAll(_supportedBlockElements);

  // this function is called recursively for each child
  // however, the first time it is called, we make sure
  // to ignore the node itself, so we only pay attention
  // to the children
  bool _hasBlockChild(dom.Node node, {bool ignoreSelf = true}) {
    bool retval = false;
    if (node is dom.Element) {
      if (_supportedBlockElements.contains(node.localName) && !ignoreSelf) {
        return true;
      }
      node.nodes.forEach((dom.Node node) {
        if (_hasBlockChild(node, ignoreSelf: false)) {
          retval = true;
        }
      });
    }
    return retval;
  }

  // Parses an html string and returns a list of RichText widgets that
  // represent the body of your html document.

  @override
  Widget build(BuildContext context) {
    String? data = html;

    if (renderNewlines) {
      data = data?.replaceAll("\n", "<br />");
    }
    final dom.Document document = parser.parse(data);
    final dom.Node? body = document.body;

    final List<Widget> widgetList = <Widget>[];
    final ParseContext parseContext = ParseContext(
      rootWidgetList: widgetList,
      childStyle: DefaultTextStyle.of(context).style,
    );

    // don't ignore the top level "body"
    _parseNode(body, parseContext, context);

    // filter out empty widgets
    final List<Widget> children = <Widget>[];
    widgetList.forEach((dynamic w) {
      if (w is BlockText) {
        if (w.child.text == null) {
          return;
        }
        final TextSpan childTextSpan = w.child.text as TextSpan;
        if ((childTextSpan.text == null ||
                (childTextSpan.text?.isEmpty ?? true)) &&
            (childTextSpan.children == null ||
                (childTextSpan.children?.isEmpty ?? true))) {
          return;
        }
      } else if (w is LinkBlock) {
        if (w.children?.isEmpty ?? true) {
          return;
        }
      } else if (w is LinkTextSpan) {
        if ((w.text?.isEmpty ?? true) && (w.children?.isEmpty ?? true)) {
          return;
        }
      }
      children.add(w as Widget);
    });

    return Column(
      children: children,
    );
  }

  // THE WORKHORSE FUNCTION!!
  // call the function with the current node and a ParseContext
  // the ParseContext is used to do a number of things
  // first, since we call this function recursively, the parseContext holds references to
  // all the data that is relevant to a particular iteration and its child iterations
  // it holds information about whether to indent the text, whether we are in a list, etc.
  //
  // secondly, it holds the 'global' widgetList that accumulates all the block-level widgets
  //
  // thirdly, it holds a reference to the most recent "parent" so that this iteration of the
  // function can add child nodes to the parent if it should
  //
  // each iteration creates a new parseContext as a copy of the previous one if it needs to
  void _parseNode(
      dom.Node? node, ParseContext parseContext, BuildContext buildContext) {
    // TEXT ONLY NODES
    // a text only node is a child of a tag with no inner html
    if (node is dom.Text) {
      final RegExp? shortcodeRegex = textMatcher;
      if (textMatcher != null && shortcodeRegex!.hasMatch(node.text)) {
        final List<Match> matches =
            shortcodeRegex.allMatches(node.text).toList();

        final Match match = matches[0];

        final String subStringStart = node.text.substring(0, match.start);
        final String subStringEnd =
            node.text.substring(match.end, node.text.length);

        final TextSpan startTextSpan = TextSpan(
            text: subStringStart, children: [], style: parseContext.childStyle);

        final TextSpan endTextSpan = TextSpan(
            text: subStringEnd, children: [], style: parseContext.childStyle);

        final dynamic widget = textReplaceFunction != null
            ? textReplaceFunction!(
                match.group(0) ?? '',
                match.groups(
                    List<int>.generate(match.groupCount, (int i) => i + 1)))
            : null;

        final BlockText startBlockText = BlockText(
          shrinkToFit: shrinkToFit ?? false,
          margin: EdgeInsets.only(
              top: 8.0,
              bottom: 8.0,
              left: parseContext.indentLevel * indentSize),
          padding: const EdgeInsets.all(2.0),
          child: RichText(
            textAlign: TextAlign.left,
            text: startTextSpan,
          ),
        );

        final BlockText endBlockText = BlockText(
          shrinkToFit: shrinkToFit ?? false,
          margin: EdgeInsets.only(
              top: 8.0,
              bottom: 8.0,
              left: parseContext.indentLevel * indentSize),
          padding: const EdgeInsets.all(2.0),
          child: RichText(
            textAlign: TextAlign.left,
            text: endTextSpan,
          ),
        );

        parseContext.rootWidgetList?.add(startBlockText);
        parseContext.rootWidgetList?.add(widget as Widget);
        parseContext.rootWidgetList?.add(endBlockText);
        parseContext.parentElement = LinkTextSpan();
      } else {
        // WHITESPACE CONSIDERATIONS ---
        // truly empty nodes should just be ignored
        if (node.text.trim() == "" && node.text.indexOf(" ") == -1) {
          return;
        }
        if (parseContext.parentElement is LinkTextSpan) {
          final LinkTextSpan linkTextSpan =
              parseContext.parentElement as LinkTextSpan;
          if (linkTextSpan.text != node.text) {
            parseContext.parentElement = null;
          }
        }

        // we might want to preserve internal whitespace
        // empty strings of whitespace might be significant or not, condense it by default
        String finalText = node.text;
        if (parseContext.condenseWhitespace) {
          finalText = condenseHtmlWhitespace(node.text);

          // if this is part of a string of spans, we will preserve leading
          // and trailing whitespace unless the previous character is whitespace
          if (parseContext.parentElement == null) {
            finalText = finalText.trimLeft();
          } else if (parseContext.parentElement is TextSpan ||
              parseContext.parentElement is LinkTextSpan) {
            String? lastString =
                parseContext.parentElement?.text as String? ?? '';
            if (!parseContext.parentElement?.children?.isEmpty) {
              lastString =
                  parseContext.parentElement?.children?.last?.text ?? '';
            }
            if (lastString!.endsWith(' ') || lastString.endsWith('\n')) {
              finalText = finalText.trimLeft();
            }
          }
        }

        // if the finalText is actually empty, just return (unless it's just a space)
        if (finalText.trim().isEmpty && finalText != " ") {
          return;
        }

        // NOW WE HAVE OUR TRULY FINAL TEXT
//        debugPrint("Plain Text Node: '$finalText'");

        // create a span by default
        final TextSpan span = TextSpan(
            text: finalText, children: [], style: parseContext.childStyle);

        //WidgetSpan(child: Text("test"))

        // in this class, a ParentElement must be a BlockText, LinkTextSpan, Row, Column, TextSpan

        // the parseContext might actually be a block level style element, so we
        // need to honor the indent and styling specified by that block style.
        // e.g. ol, ul, blockquote
        final bool treatLikeBlock =
            ['blockquote', 'ul', 'ol'].indexOf(parseContext.blockType ?? '') !=
                -1;

        // if there is no parentElement, contain the span in a BlockText
        if (parseContext.parentElement == null) {
          // if this is inside a context that should be treated like a block
          // but the context is not actually a block, create a block
          // and append it to the root widget tree
          if (treatLikeBlock) {
            Decoration? decoration;
            if (parseContext.blockType == 'blockquote') {
              decoration = const BoxDecoration(
                border:
                    Border(left: BorderSide(color: Colors.black38, width: 2.0)),
              );
              parseContext.childStyle =
                  parseContext.childStyle?.merge(const TextStyle(
                fontStyle: FontStyle.italic,
              ));
            }
            final BlockText blockText = BlockText(
              shrinkToFit: shrinkToFit ?? false,
              margin: EdgeInsets.only(
                  top: 8.0,
                  bottom: 8.0,
                  left: parseContext.indentLevel * indentSize),
              padding: const EdgeInsets.all(2.0),
              decoration: decoration,
              child: RichText(
                textAlign: TextAlign.left,
                text: span,
              ),
            );
            parseContext.rootWidgetList?.add(blockText);
          } else {
            parseContext.rootWidgetList?.add(BlockText(
              shrinkToFit: shrinkToFit ?? false,
              child: RichText(text: span),
            ));
          }
          // this allows future items to be added as children of this item
          parseContext.parentElement = span;

          // if the parent is a LinkTextSpan, keep the main attributes of that span going.
        } else if (parseContext.parentElement is LinkTextSpan) {
        } else if (parseContext.parentElement.children is! List<Widget>) {
          parseContext.parentElement.children.add(span);
        } else {
          // Doing nothing... we shouldn't ever get here
        }
        return;
      }
    }

    // OTHER ELEMENT NODES
    else if (node is dom.Element) {
      if (!_supportedElements.contains(node.localName)) {
        return;
      }

      // make a copy of the current context so that we can modify
      // pieces of it for the next iteration of this function
      final ParseContext nextContext = ParseContext.fromContext(parseContext);

      // handle style elements
      if (_supportedStyleElements.contains(node.localName)) {
        TextStyle childStyle = parseContext.childStyle ?? const TextStyle();

        switch (node.localName) {
          //"b","i","em","strong","code","u","small","abbr","acronym"
          case "b":
          case "strong":
            childStyle =
                childStyle.merge(const TextStyle(fontWeight: FontWeight.bold));
            break;
          case "i":
          case "address":
          case "cite":
          case "var":
          case "em":
            childStyle =
                childStyle.merge(const TextStyle(fontStyle: FontStyle.italic));
            break;
          case "kbd":
          case "samp":
          case "tt":
          case "code":
            childStyle =
                childStyle.merge(const TextStyle(fontFamily: 'monospace'));
            break;
          case "ins":
          case "u":
            childStyle = childStyle
                .merge(const TextStyle(decoration: TextDecoration.underline));
            break;
          case "abbr":
          case "acronym":
            childStyle = childStyle.merge(const TextStyle(
              decoration: TextDecoration.underline,
              decorationStyle: TextDecorationStyle.dotted,
            ));
            break;
          case "big":
            childStyle = childStyle.merge(const TextStyle(fontSize: 20.0));
            break;
          case "small":
            childStyle = childStyle.merge(const TextStyle(fontSize: 10.0));
            break;
          case "mark":
            childStyle = childStyle.merge(const TextStyle(
                backgroundColor: Colors.yellow, color: Colors.black));
            break;
          case "sub":
            childStyle = childStyle.merge(
              TextStyle(
                fontSize:
                    childStyle.fontSize ?? 0 * OFFSET_TAGS_FONT_SIZE_FACTOR,
              ),
            );
            break;
          case "del":
          case "s":
          case "strike":
            childStyle = childStyle
                .merge(const TextStyle(decoration: TextDecoration.lineThrough));
            break;
          case "ol":
            nextContext.indentLevel += 1;
            nextContext.listChar = '#';
            nextContext.listCount = 0;
            nextContext.blockType = 'ol';
            break;
          case "ul":
            nextContext.indentLevel += 1;
            nextContext.listChar = '•';
            nextContext.listCount = 0;
            nextContext.blockType = 'ul';
            break;
          case "blockquote":
            nextContext.indentLevel += 1;
            nextContext.blockType = 'blockquote';
            break;
          case "ruby":
          case "rt":
          case "rp":
          case "bdi":
          case "data":
          case "time":
          case "span":
            //No additional styles
            break;
        }

        if (customTextStyle != null) {
          final TextStyle? customStyle = customTextStyle != null
              ? customTextStyle!(node, childStyle)
              : null;
          if (customStyle != null) {
            childStyle = customStyle;
          }
        }

        nextContext.childStyle = childStyle;
      }

      // handle specialty elements
      else if (_supportedSpecialtyElements.contains(node.localName)) {
        // should support "a","br","table","tbody","thead","tfoot","th","tr","td"
        print(node.children.toString());
        switch (node.localName) {
          case "a":
            // if this item has block children, we create
            // a container and gesture recognizer for the entire
            // element, otherwise, we create a LinkTextSpan
            final String? url = node.attributes['href'] ?? null;

            if (_hasBlockChild(node)) {
              parseContext.parentElement.removeLast();

              final Widget? linkWidget = textReplaceFunction != null
                  ? textReplaceFunction!(url ?? '', ["link", url, node.text])
                  : null;

              parseContext.rootWidgetList?.add(linkWidget ?? Container());
            } else {
              final Widget? linkWidget = textReplaceFunction != null
                  ? textReplaceFunction!(url ?? '', ["link", url, node.text])
                  : null;

              if (parseContext.parentElement is TextSpan) {
                parseContext.rootWidgetList?.add(linkWidget ?? Container());
              } else {
                // start a new block element for this link and its text
                final Widget? linkWidget = textReplaceFunction != null
                    ? textReplaceFunction!(url ?? '', ["link", url, node.text])
                    : null;

                parseContext.rootWidgetList?.add(linkWidget ?? Container());
              }
              parseContext.parentElement = LinkTextSpan(text: node.text);
              nextContext.parentElement = LinkTextSpan(text: node.text);
            }
            break;

          case "br":
            if (parseContext.parentElement != null &&
                parseContext.parentElement is TextSpan) {
              parseContext.parentElement.children
                  .add(const TextSpan(text: '\n', children: []));
            }
            break;

          case "table":
            // new block, so clear out the parent element
            parseContext.parentElement = null;
            nextContext.parentElement = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[],
            );
            nextContext.rootWidgetList?.add(Container(
                margin: const EdgeInsets.symmetric(vertical: 12.0),
                child: nextContext.parentElement as Widget));
            break;

          // we don't handle tbody, thead, or tfoot elements separately for now
          case "tbody":
          case "thead":
          case "tfoot":
            break;

          case "td":
          case "th":
            int colspan = 1;
            if (node.attributes['colspan'] != null) {
              colspan = int.tryParse(node.attributes['colspan'] ?? '') ?? 0;
            }
            nextContext.childStyle = nextContext.childStyle?.merge(TextStyle(
                fontWeight: (node.localName == 'th')
                    ? FontWeight.bold
                    : FontWeight.normal));
            final RichText text = RichText(
                text: const TextSpan(text: '', children: <TextSpan>[]));
            final Expanded cell = Expanded(
              flex: colspan,
              child: Container(padding: const EdgeInsets.all(1.0), child: text),
            );
            nextContext.parentElement.children.add(cell);
            nextContext.parentElement = text.text;
            break;

          case "tr":
            final Row row = Row(
              children: <Widget>[],
            );
            nextContext.parentElement.children.add(row);
            nextContext.parentElement = row;
            break;

          // treat captions like a row with one expanded cell
          case "caption":
            // create the row
            final Row row = Row(
              children: <Widget>[],
            );

            // create an expanded cell
            final RichText text = RichText(
                textAlign: TextAlign.center,
                textScaleFactor: 1.2,
                text: const TextSpan(text: '', children: <TextSpan>[]));
            final Expanded cell = Expanded(
              child: Container(padding: const EdgeInsets.all(2.0), child: text),
            );
            row.children.add(cell);
            nextContext.parentElement.children.add(row);
            nextContext.parentElement = text.text;
            break;
          case "q":
            if (parseContext.parentElement != null &&
                parseContext.parentElement is TextSpan) {
              parseContext.parentElement.children
                  .add(const TextSpan(text: '"', children: []));
              const TextSpan content = TextSpan(text: '', children: []);
              parseContext.parentElement.children.add(content);
              parseContext.parentElement.children
                  .add(const TextSpan(text: '"', children: []));
              nextContext.parentElement = content;
            }
            break;
        }

        if (customTextStyle != null) {
          final TextStyle customStyle =
              customTextStyle!(node, nextContext.childStyle);
          if (customStyle != null) {
            nextContext.childStyle = customStyle;
          }
        }
      }

      // handle block elements
      else if (_supportedBlockElements.contains(node.localName)) {
        // block elements only show up at the "root" widget level
        // so if we have a block element, reset the parentElement to null
        parseContext.parentElement = null;
        TextAlign textAlign = TextAlign.left;
        if (customTextAlign != null) {
          textAlign = customTextAlign!(node) ?? textAlign;
        }

        EdgeInsets? _customEdgeInsets;
        if (customEdgeInsets != null) {
          _customEdgeInsets = customEdgeInsets!(node);
        }

        switch (node.localName) {
          case "hr":
            parseContext.rootWidgetList
                ?.add(const Divider(height: 1.0, color: Colors.black38));
            break;
          case "img":
            if (showImages) {
              if (node.attributes['src'] != null) {
                final double? width = imageProperties?.width ??
                    ((node.attributes['width'] != null)
                        ? double.tryParse(node.attributes['width'] ?? '')
                        : null);
                final double? height = imageProperties?.height ??
                    ((node.attributes['height'] != null)
                        ? double.tryParse(node.attributes['height'] ?? '')
                        : null);

                if ((node.attributes['src']?.startsWith("data:image") ??
                        false) &&
                    (node.attributes['src']?.contains("base64,") ?? false)) {
                  precacheImage(
                    MemoryImage(
                      base64.decode(
                        node.attributes['src']?.split("base64,")[1].trim() ??
                            '',
                      ),
                    ),
                    buildContext,
                    onError: onImageError ?? (_, __) {},
                  );
                  parseContext.rootWidgetList?.add(GestureDetector(
                    child: Image.memory(
                      base64.decode(
                          node.attributes['src']?.split("base64,")[1].trim() ??
                              ''),
                      width: (width ?? -1) > 0 ? width : null,
                      height: (height ?? -1) > 0 ? width : null,
                      scale: imageProperties?.scale ?? 1.0,
                      matchTextDirection:
                          imageProperties?.matchTextDirection ?? false,
                      centerSlice: imageProperties?.centerSlice,
                      filterQuality:
                          imageProperties?.filterQuality ?? FilterQuality.low,
                      alignment: imageProperties?.alignment ?? Alignment.center,
                      colorBlendMode: imageProperties?.colorBlendMode,
                      fit: imageProperties?.fit,
                      color: imageProperties?.color,
                      repeat: imageProperties?.repeat ?? ImageRepeat.noRepeat,
                      semanticLabel: imageProperties?.semanticLabel,
                      excludeFromSemantics:
                          (imageProperties?.semanticLabel == null)
                              ? true
                              : false,
                    ),
                    onTap: () {
                      if (onImageTap != null) {
                        onImageTap!(node.attributes['src'] ?? '');
                      }
                    },
                  ));
                } else {
                  precacheImage(
                    NetworkImage(node.attributes['src'] ?? ''),
                    buildContext,
                    onError: onImageError ?? (_, __) {},
                  );
                  parseContext.rootWidgetList?.add(GestureDetector(
                    child: Image.network(
                      node.attributes['src'] ?? '',
                      frameBuilder:
                          (BuildContext context, Widget child, int? frame, _) {
                        if (node.attributes['alt'] != null && frame == null) {
                          return BlockText(
                            shrinkToFit: shrinkToFit ?? false,
                            child: RichText(
                              textAlign: TextAlign.center,
                              text: TextSpan(
                                text: node.attributes['alt'],
                                style: nextContext.childStyle,
                              ),
                            ),
                          );
                        }
                        if (frame != null) {
                          return child;
                        }
                        return Container();
                      },
                      width: (width ?? -1) > 0 ? width : null,
                      height: (height ?? -1) > 0 ? height : null,
                      scale: imageProperties?.scale ?? 1.0,
                      matchTextDirection:
                          imageProperties?.matchTextDirection ?? false,
                      centerSlice: imageProperties?.centerSlice,
                      filterQuality:
                          imageProperties?.filterQuality ?? FilterQuality.low,
                      alignment: imageProperties?.alignment ?? Alignment.center,
                      colorBlendMode: imageProperties?.colorBlendMode,
                      fit: imageProperties?.fit,
                      color: imageProperties?.color,
                      repeat: imageProperties?.repeat ?? ImageRepeat.noRepeat,
                      semanticLabel: imageProperties?.semanticLabel,
                      excludeFromSemantics:
                          (imageProperties?.semanticLabel == null)
                              ? true
                              : false,
                    ),
                    onTap: () {
                      if (onImageTap != null) {
                        onImageTap!(node.attributes['src'] ?? '');
                      }
                    },
                  ));
                }
              }
            }
            break;
          case "li":
            String leadingChar = parseContext.listChar;
            if (parseContext.blockType == 'ol') {
              // nextContext will handle nodes under this 'li'
              // but we want to increment the count at this level
              parseContext.listCount += 1;
              leadingChar = parseContext.listCount.toString() + '.';
            }
            final BlockText blockText = BlockText(
              shrinkToFit: shrinkToFit ?? false,
              margin: EdgeInsets.only(
                  left: parseContext.indentLevel * indentSize, top: 3.0),
              child: RichText(
                text: TextSpan(
                  text: '$leadingChar  ',
                  style: DefaultTextStyle.of(buildContext).style,
                  children: <TextSpan>[
                    TextSpan(text: '', style: nextContext.childStyle)
                  ],
                ),
              ),
            );
            parseContext.rootWidgetList?.add(blockText);
            nextContext.parentElement = blockText.child.text;
            nextContext.spansOnly = true;
            nextContext.inBlock = true;
            break;

          case "h1":
            nextContext.childStyle = nextContext.childStyle?.merge(
              const TextStyle(fontSize: 26.0, fontWeight: FontWeight.bold),
            );
            continue myDefault;
          case "h2":
            nextContext.childStyle = nextContext.childStyle?.merge(
              const TextStyle(fontSize: 24.0, fontWeight: FontWeight.bold),
            );
            continue myDefault;
          case "h3":
            nextContext.childStyle = nextContext.childStyle?.merge(
              const TextStyle(fontSize: 22.0, fontWeight: FontWeight.bold),
            );
            continue myDefault;
          case "h4":
            nextContext.childStyle = nextContext.childStyle?.merge(
              const TextStyle(fontSize: 20.0, fontWeight: FontWeight.w100),
            );
            continue myDefault;
          case "h5":
            nextContext.childStyle = nextContext.childStyle?.merge(
              const TextStyle(fontSize: 18.0, fontWeight: FontWeight.bold),
            );
            continue myDefault;
          case "h6":
            nextContext.childStyle = nextContext.childStyle?.merge(
              const TextStyle(fontSize: 18.0, fontWeight: FontWeight.w100),
            );
            continue myDefault;

          case "pre":
            nextContext.condenseWhitespace = false;
            continue myDefault;

          case "center":
            textAlign = TextAlign.center;
            // no break here
            continue myDefault;

          myDefault:
          default:
            Decoration? decoration;
            if (parseContext.blockType == 'blockquote') {
              decoration = const BoxDecoration(
                border:
                    Border(left: BorderSide(color: Colors.black38, width: 2.0)),
              );
              nextContext.childStyle =
                  nextContext.childStyle?.merge(const TextStyle(
                fontStyle: FontStyle.italic,
              ));
            }
            final BlockText blockText = BlockText(
              shrinkToFit: shrinkToFit ?? false,
              margin: node.localName != 'body'
                  ? _customEdgeInsets ??
                      EdgeInsets.only(
                          top: 8.0,
                          bottom: 8.0,
                          left: parseContext.indentLevel * indentSize)
                  : EdgeInsets.zero,
              padding: const EdgeInsets.all(2.0),
              decoration: decoration,
              child: RichText(
                textAlign: textAlign,
                text: TextSpan(
                  text: '',
                  style: nextContext.childStyle,
                  children: <TextSpan>[],
                ),
              ),
            );

            parseContext.rootWidgetList?.add(blockText);
            nextContext.parentElement = blockText.child.text;
            nextContext.spansOnly = true;
            nextContext.inBlock = true;
        }

        if (customTextStyle != null) {
          final TextStyle? customStyle =
              customTextStyle!(node, nextContext.childStyle);
          if (customStyle != null) {
            nextContext.childStyle = customStyle;
          }
        }
      }
      node.nodes.forEach((dom.Node childNode) {
        _parseNode(childNode, nextContext, buildContext);
      });
    }
  }

  String condenseHtmlWhitespace(String stringToTrim) {
    stringToTrim = stringToTrim.replaceAll("\n", " ");
    while (stringToTrim.indexOf("  ") != -1) {
      stringToTrim = stringToTrim.replaceAll("  ", " ");
    }
    return stringToTrim;
  }
}
