package org.findmyfam.ui.common

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
// Wildcard: circle()/roundCorners()/solid()/rect() etc. are top-level
// extension functions on the shape/brush companions, not members -- a
// plain per-type import wouldn't pull those in.
import io.github.alexzhirkevich.qrose.options.*
import io.github.alexzhirkevich.qrose.rememberQrCodePainter

/**
 * Sampled from the app icon's background (averaged, excluding the bolt mark
 * and transparent corners) -- see iOS's QRCodeView.swift for the derivation.
 */
private val BrandDarkGrey = Color(0xFF2A3040)

/**
 * Generates and displays a QR code from the given [content] string, styled
 * with rounded/dot modules and tinted to the brand dark grey instead of a
 * raw black-on-white barcode look.
 *
 * Pass [logoPainter] (e.g. `R.drawable.invite_qr_mark`) to badge the
 * center. Must be a VectorDrawable or a rasterized asset (PNG/JPG/WEBP) --
 * `painterResource(R.mipmap.ic_launcher)` throws IllegalArgumentException
 * on API 26+ (this app's minSdk), where that resource always resolves to
 * the `<adaptive-icon>` XML in mipmap-anydpi-v26, not a drawable.
 *
 * Passing a logo bumps error correction to [QrErrorCorrectionLevel.Medium] -- enough
 * redundancy for a small badge without paying the much higher module count
 * [QrErrorCorrectionLevel.High] needs. With no logo, [QrErrorCorrectionLevel.Low]
 * keeps the module count, and so the apparent density, as low as the
 * content allows.
 */
@Composable
fun QrCodeImage(
    content: String,
    size: Dp = 200.dp,
    modifier: Modifier = Modifier,
    logoPainter: Painter? = null
) {
    val painter = rememberQrCodePainter(
        data = content,
        shapes = QrShapes(
            darkPixel = QrPixelShape.circle(.85f),
            ball = QrBallShape.roundCorners(.25f),
            frame = QrFrameShape.roundCorners(.25f)
        ),
        colors = QrColors(
            dark = QrBrush.solid(BrandDarkGrey),
            ball = QrBrush.solid(BrandDarkGrey),
            frame = QrBrush.solid(BrandDarkGrey)
        ),
        logo = QrLogo(
            painter = logoPainter,
            size = 0.18f,
            padding = QrLogoPadding.Accurate(.15f),
            shape = QrLogoShape.rect(aspectRatio = 1f, cornerRadius = .3f)
        ),
        errorCorrectionLevel = if (logoPainter != null) {
            QrErrorCorrectionLevel.Medium
        } else {
            QrErrorCorrectionLevel.Low
        }
    )

    Box(
        modifier = modifier
            .size(size)
            .clip(RoundedCornerShape(12.dp))
            .background(Color.White),
        contentAlignment = Alignment.Center
    ) {
        Image(
            painter = painter,
            contentDescription = "QR Code",
            modifier = Modifier.size(size - 16.dp)
        )
    }
}
