import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

const _shareQrBrandTitle = '小黄鸭分享';
const _shareQrOrange = Color(0xFFF97316);
const _shareQrOrangeDark = Color(0xFF9A3412);
const _shareQrOrangeSoft = Color(0xFFFFF7ED);
const _shareQrOrangeBorder = Color(0xFFFDBA74);

class ShareQRCodePanel extends StatelessWidget {
  final String link;
  final String? title;
  final double size;

  const ShareQRCodePanel({
    super.key,
    required this.link,
    this.title,
    this.size = 230,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final label = title?.trim() ?? '';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          decoration: BoxDecoration(
            color: _shareQrOrangeSoft,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _shareQrOrangeBorder),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                _shareQrBrandTitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: _shareQrOrangeDark,
                ),
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) {
                  final qrSide = math.min(size, constraints.maxWidth);
                  return Container(
                    width: qrSide,
                    height: qrSide,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: _shareQrOrangeBorder),
                      boxShadow: [
                        BoxShadow(
                          color: _shareQrOrange.withValues(alpha: 0.14),
                          blurRadius: 18,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: QrImageView(
                      data: link,
                      backgroundColor: Colors.white,
                      eyeStyle: const QrEyeStyle(
                        eyeShape: QrEyeShape.square,
                        color: Colors.black,
                      ),
                      dataModuleStyle: const QrDataModuleStyle(
                        dataModuleShape: QrDataModuleShape.square,
                        color: Colors.black,
                      ),
                    ),
                  );
                },
              ),
              if (label.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: _shareQrOrangeDark,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: cs.muted,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: cs.border),
          ),
          child: SelectableText(
            link,
            style: TextStyle(fontSize: 12, color: cs.foreground),
          ),
        ),
      ],
    );
  }
}

Future<void> copyShareQRCodeToClipboard(String link, {String? title}) async {
  final bytes = await createShareQRCodePng(link, title: title);
  await Pasteboard.writeImage(bytes);
}

Future<Uint8List> createShareQRCodePng(
  String link, {
  String? title,
  double size = 720,
}) async {
  final label = title?.trim() ?? '';
  final outerWidth = size;
  final margin = size * 0.042;
  final cardPaddingX = size * 0.058;
  final cardPaddingTop = size * 0.052;
  final cardPaddingBottom = size * 0.058;
  final gap = size * 0.034;
  final qrSize = size * 0.58;
  final qrInset = size * 0.026;
  final textWidth = outerWidth - (margin + cardPaddingX) * 2;

  final brandPainter = TextPainter(
    text: TextSpan(
      text: _shareQrBrandTitle,
      style: TextStyle(
        color: _shareQrOrangeDark,
        fontSize: size * 0.056,
        fontWeight: FontWeight.w800,
        height: 1.16,
      ),
    ),
    textAlign: TextAlign.center,
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout(maxWidth: textWidth);

  final titlePainter = TextPainter(
    text: TextSpan(
      text: label,
      style: TextStyle(
        color: const Color(0xFF111827),
        fontSize: size * 0.042,
        fontWeight: FontWeight.w700,
        height: 1.22,
      ),
    ),
    textAlign: TextAlign.center,
    textDirection: TextDirection.ltr,
    maxLines: 2,
    ellipsis: '...',
  )..layout(maxWidth: textWidth);

  final cardHeight =
      cardPaddingTop +
      brandPainter.height +
      gap +
      qrSize +
      (label.isEmpty ? 0 : gap + titlePainter.height) +
      cardPaddingBottom;
  final outerHeight = cardHeight + margin * 2;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(_shareQrOrangeSoft, BlendMode.src);

  final cardRect = Rect.fromLTWH(
    margin,
    margin,
    outerWidth - margin * 2,
    cardHeight,
  );
  final cardRRect = RRect.fromRectAndRadius(
    cardRect,
    const Radius.circular(24),
  );

  canvas.drawRRect(
    cardRRect.shift(Offset(0, size * 0.012)),
    Paint()..color = _shareQrOrange.withValues(alpha: 0.14),
  );
  canvas.drawRRect(cardRRect, Paint()..color = Colors.white);
  canvas.drawRRect(
    cardRRect,
    Paint()
      ..color = _shareQrOrangeBorder
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2,
  );

  brandPainter.paint(
    canvas,
    Offset((outerWidth - brandPainter.width) / 2, margin + cardPaddingTop),
  );

  final qrOuterRect = Rect.fromLTWH(
    (outerWidth - qrSize) / 2,
    margin + cardPaddingTop + brandPainter.height + gap,
    qrSize,
    qrSize,
  );
  final qrOuterRRect = RRect.fromRectAndRadius(
    qrOuterRect,
    const Radius.circular(16),
  );
  canvas.drawRRect(qrOuterRRect, Paint()..color = Colors.white);
  canvas.drawRRect(
    qrOuterRRect,
    Paint()
      ..color = _shareQrOrangeBorder
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2,
  );

  final qrRect = qrOuterRect.deflate(qrInset);
  canvas.save();
  canvas.translate(qrRect.left, qrRect.top);
  QrPainter(
    data: link,
    version: QrVersions.auto,
    gapless: false,
    eyeStyle: const QrEyeStyle(
      eyeShape: QrEyeShape.square,
      color: Colors.black,
    ),
    dataModuleStyle: const QrDataModuleStyle(
      dataModuleShape: QrDataModuleShape.square,
      color: Colors.black,
    ),
  ).paint(canvas, qrRect.size);
  canvas.restore();

  if (label.isNotEmpty) {
    titlePainter.paint(
      canvas,
      Offset((outerWidth - titlePainter.width) / 2, qrOuterRect.bottom + gap),
    );
  }

  final image = await recorder.endRecording().toImage(
    outerWidth.round(),
    outerHeight.round(),
  );
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  if (byteData == null) throw StateError('无法生成二维码图片');
  return byteData.buffer.asUint8List();
}
