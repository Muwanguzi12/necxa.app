package com.necxa

import android.graphics.Rect
import android.graphics.PointF
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceContour
import com.google.mlkit.vision.face.FaceDetector
import com.google.mlkit.vision.face.FaceDetectorOptions
import com.cloudwebrtc.webrtc.video.LocalVideoTrack
import org.webrtc.JavaI420Buffer
import org.webrtc.VideoFrame
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max
import kotlin.math.min

/**
 * High-performance, battery-efficient, fail-open face contour & symmetry processor
 * for the WebRTC local camera track.
 *
 * Optimizations:
 * Reuses conversion/row buffers, throttles on-device ML Kit detection, and
 * degrades face-processing quality when frame processing exceeds its budget.
 */
internal data class FaceLandmarkState(
    val bounds: Rect,
    val faceOutline: List<PointF>,
    val leftCheek: List<PointF>,
    val rightCheek: List<PointF>,
    val upperLip: List<PointF>,
    val lowerLip: List<PointF>
)

internal class FaceBeautyFrameProcessor : LocalVideoTrack.ExternalVideoFrameProcessing {
    @Volatile var intensity: Float = 0.35f
    @Volatile var mirrorLeft: Boolean? = null
    @Volatile var smoothing: Float = 0f
    @Volatile var brightness: Float = 0f
    @Volatile var contrast: Float = 1f
    @Volatile var saturation: Float = 1f
    @Volatile var hue: Float = 0f
    @Volatile var warmth: Float = 0f
    @Volatile var makeupGender: Int = 0
    @Volatile var makeupStyle: Int = 0
    @Volatile var makeupIntensity: Float = 0f

    private val detector: FaceDetector = FaceDetection.getClient(
        FaceDetectorOptions.Builder()
            .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_FAST)
            .setLandmarkMode(FaceDetectorOptions.LANDMARK_MODE_ALL)
            .setClassificationMode(FaceDetectorOptions.CLASSIFICATION_MODE_NONE)
            .setContourMode(FaceDetectorOptions.CONTOUR_MODE_ALL)
            .setMinFaceSize(0.15f)
            .build()
    )

    private val detecting = AtomicBoolean(false)
    @Volatile private var face: Rect? = null
    @Volatile private var faceLandmarks: FaceLandmarkState? = null
    private var frameCount = 0
    private var missedDetectionCount = 0
    @Volatile private var averageFrameNanos = 0L
    @Volatile private var maxFrameNanos = 0L
    @Volatile private var slowFrameCount = 0L
    @Volatile private var processedFrameCount = 0L
    @Volatile private var processingErrorCount = 0L
    @Volatile private var closed = false

    // Zero-allocation buffer caches (reused across frames to eliminate GC and battery drain)
    private var cachedNv21: ByteBuffer? = null
    private var cachedNv21Capacity = 0
    private var transferBuffer = ByteArray(2048)
    private var uRowCache = ByteArray(1024)
    private var vRowCache = ByteArray(1024)
    private var uvInterleavedCache = ByteArray(2048)

    override fun onFrame(frame: VideoFrame): VideoFrame {
        if (closed) return frame
        val frameStartedAt = System.nanoTime()
        val averageCost = averageFrameNanos
        // Under sustained load, reduce expensive face warping first and slow
        // detector cadence. Colour grading remains available.
        val amount = if (averageCost > 28_000_000L) 0f else intensity.coerceIn(0f, 1f)
        val smooth = (if (averageCost > 18_000_000L) smoothing * 0.5f else smoothing).coerceIn(0f, 1f)
        val bright = brightness.coerceIn(-0.25f, 0.25f)
        val contrastAmount = contrast.coerceIn(0.5f, 1.8f)
        val saturationAmount = saturation.coerceIn(0f, 2f)
        val hueAmount = hue.coerceIn(-3.14159f, 3.14159f)
        val warmthAmount = warmth.coerceIn(-0.5f, 0.5f)
        val makeupAmount = makeupIntensity.coerceIn(0f, 1f)
        val makeupMode = makeupGender.coerceIn(0, 2)
        val needsFace = amount > 0.01f || smooth > 0.01f || (makeupMode > 0 && makeupAmount > 0.01f)
        if (!needsFace && kotlin.math.abs(bright) < 0.001f &&
            kotlin.math.abs(contrastAmount - 1f) < 0.001f &&
            kotlin.math.abs(saturationAmount - 1f) < 0.001f &&
            kotlin.math.abs(hueAmount) < 0.001f &&
            kotlin.math.abs(warmthAmount) < 0.001f) {
            face = null
            faceLandmarks = null
            return frame
        }

        return try {
            val source = frame.buffer.toI420() ?: return frame
            // Guard: skip processing on degenerate frames (camera initializing or flipping)
            if (source.width <= 0 || source.height <= 0) {
                source.release()
                return frame
            }
            var output: JavaI420Buffer? = null
            var outputRetained = false
            var sourceReleased = false
            try {
                frameCount++
                val detectionInterval = when {
                    averageCost > 28_000_000L -> 15
                    averageCost > 20_000_000L -> 10
                    else -> 6
                }
                if (needsFace && frameCount % detectionInterval == 0 && detecting.compareAndSet(false, true)) {
                    detect(source, frame.rotation)
                }

                val bounds = face
                val hasColourGrade = kotlin.math.abs(bright) >= 0.001f ||
                    kotlin.math.abs(contrastAmount - 1f) >= 0.001f ||
                    kotlin.math.abs(saturationAmount - 1f) >= 0.001f ||
                    kotlin.math.abs(hueAmount) >= 0.001f ||
                    kotlin.math.abs(warmthAmount) >= 0.001f
                if (bounds == null && smooth <= 0.01f && !hasColourGrade &&
                    (makeupMode == 0 || makeupAmount <= 0.01f || faceLandmarks == null)) {
                    // Symmetry is enabled but no face has been detected yet: preserve
                    // the original frame without allocating/copying an identical I420 buffer.
                    source.release()
                    sourceReleased = true
                    return frame
                }
                output = JavaI420Buffer.allocate(source.width, source.height)

                if (amount > 0.01f && bounds != null) {
                    warpPlane(source.dataY, source.strideY, output.dataY, output.strideY,
                        source.width, source.height, bounds, amount)
                    warpPlane(source.dataU, source.strideU, output.dataU, output.strideU,
                        source.width / 2, source.height / 2, scale(bounds, 0.5f), amount)
                    warpPlane(source.dataV, source.strideV, output.dataV, output.strideV,
                        source.width / 2, source.height / 2, scale(bounds, 0.5f), amount)
                } else {
                    copyPlane(source.dataY, source.strideY, output.dataY, output.strideY, source.width, source.height)
                    copyPlane(source.dataU, source.strideU, output.dataU, output.strideU, source.width / 2, source.height / 2)
                    copyPlane(source.dataV, source.strideV, output.dataV, output.strideV, source.width / 2, source.height / 2)
                }

                if (smooth > 0.01f && bounds != null) {
                    applySkinSmoothing(source.dataY, source.strideY, source.dataU,
                        source.strideU, source.dataV, source.strideV, output.dataY,
                        output.strideY, source.width, source.height, bounds, smooth,
                        faceLandmarks?.faceOutline.orEmpty())
                }
                if (kotlin.math.abs(bright) >= 0.001f ||
                    kotlin.math.abs(contrastAmount - 1f) >= 0.001f) {
                    applyColourGrade(output.dataY, output.strideY, source.width, source.height,
                        bright, contrastAmount)
                }
                if (kotlin.math.abs(saturationAmount - 1f) >= 0.001f ||
                    kotlin.math.abs(warmthAmount) >= 0.001f) {
                    applyChromaGrade(output.dataU, output.strideU, output.dataV, output.strideV,
                        source.width / 2, source.height / 2, saturationAmount, hueAmount, warmthAmount)
                }
                if (makeupMode > 0 && makeupAmount > 0.01f) {
                    faceLandmarks?.let {
                        applyMakeup(output.dataU, output.strideU, output.dataV, output.strideV,
                            source.width / 2, source.height / 2, it, makeupMode,
                            makeupStyle.coerceIn(0, 2), makeupAmount)
                    }
                }

                output.dataY.position(0)
                output.dataU.position(0)
                output.dataV.position(0)

                val resultFrame = VideoFrame(output, frame.rotation, frame.timestampNs)
                outputRetained = true
                resultFrame
            } finally {
                if (!sourceReleased) source.release()
                if (!outputRetained) output?.release()
            }
        } catch (_: Throwable) {
            processingErrorCount++
            frame
        } finally {
            val elapsed = System.nanoTime() - frameStartedAt
            averageFrameNanos = if (averageFrameNanos == 0L) elapsed
                else (averageFrameNanos * 7L + elapsed) / 8L
            if (elapsed > maxFrameNanos) maxFrameNanos = elapsed
            if (elapsed > 33_333_333L) slowFrameCount++
            processedFrameCount++
        }
    }

    fun performanceStats(): Map<String, Long> = mapOf(
        "averageFrameNanos" to averageFrameNanos,
        "maxFrameNanos" to maxFrameNanos,
        "slowFramesOver33ms" to slowFrameCount,
        "processedFrames" to processedFrameCount,
        "processingErrors" to processingErrorCount
    )

    private fun detect(buffer: org.webrtc.VideoFrame.I420Buffer, rotation: Int) {
        try {
            val w = buffer.width
            val h = buffer.height
            val nv21 = getOrCreateNv21(w * h * 3 / 2)
            val y = buffer.dataY
            if (buffer.strideY == w) {
                y.position(0); y.limit(w * h); nv21.put(y)
            } else {
                val rowBytes = getTransferBuffer(w)
                for (row in 0 until h) {
                    y.position(row * buffer.strideY); y.get(rowBytes, 0, w); nv21.put(rowBytes, 0, w)
                }
            }
            val halfW = w / 2
            val halfH = h / 2
            ensureUvCaches(halfW)
            for (row in 0 until halfH) {
                buffer.dataV.position(row * buffer.strideV)
                buffer.dataV.get(vRowCache, 0, halfW)
                buffer.dataU.position(row * buffer.strideU)
                buffer.dataU.get(uRowCache, 0, halfW)
                var idx = 0
                for (col in 0 until halfW) {
                    uvInterleavedCache[idx++] = vRowCache[col]
                    uvInterleavedCache[idx++] = uRowCache[col]
                }
                nv21.put(uvInterleavedCache, 0, w)
            }
            nv21.flip()
            val image = InputImage.fromByteBuffer(nv21, w, h, rotation, InputImage.IMAGE_FORMAT_NV21)
            detector.process(image)
                .addOnSuccessListener { faces ->
                    val detected = faces.maxByOrNull { it.boundingBox.width() * it.boundingBox.height() }
                    if (detected == null) {
                        missedDetectionCount++
                        if (missedDetectionCount > 4) { face = null; faceLandmarks = null }
                    } else {
                        missedDetectionCount = 0
                        val mapped = FaceCoordinateMapper.mapRect(
                            detected.boundingBox.left, detected.boundingBox.top,
                            detected.boundingBox.right, detected.boundingBox.bottom, w, h, rotation
                        )
                        val mappedRect = Rect(mapped.left, mapped.top, mapped.right, mapped.bottom)
                        val old = face
                        val smoothed = if (old == null) mappedRect else Rect(
                            blend(old.left, mapped.left), blend(old.top, mapped.top),
                            blend(old.right, mapped.right), blend(old.bottom, mapped.bottom)
                        )
                        face = smoothed
                        fun contour(type: Int): List<PointF> =
                            detected.getContour(type)?.points?.map { p ->
                                FaceCoordinateMapper.mapPoint(p.x, p.y, w, h, rotation)
                                    .let { PointF(it.x, it.y) }
                            } ?: emptyList()
                        faceLandmarks = FaceLandmarkState(
                            smoothed, contour(FaceContour.FACE),
                            contour(FaceContour.LEFT_CHEEK), contour(FaceContour.RIGHT_CHEEK),
                            contour(FaceContour.UPPER_LIP_TOP), contour(FaceContour.LOWER_LIP_BOTTOM)
                        )
                    }
                }
                .addOnFailureListener {
                    missedDetectionCount++
                    if (missedDetectionCount > 4) { face = null; faceLandmarks = null }
                }
                .addOnCompleteListener { detecting.set(false) }
        } catch (_: Throwable) {
            detecting.set(false)
        }
    }

    private fun copyPlane(
        src: ByteBuffer, srcStride: Int, dst: ByteBuffer, dstStride: Int,
        width: Int, height: Int
    ) {
        for (row in 0 until height) copyRowChunk(src, row * srcStride, dst, row * dstStride, width)
    }

    /**
     * Lightweight face-region luma smoothing. It blends a small 3x3 neighbourhood
     * with the original frame only inside the detected face bounds; no full-frame
     * bitmap, texture upload, or per-frame temporary allocation is required.
     */
    private fun applySkinSmoothing(
        source: ByteBuffer, sourceStride: Int,
        sourceU: ByteBuffer, sourceUStride: Int,
        sourceV: ByteBuffer, sourceVStride: Int,
        target: ByteBuffer, targetStride: Int,
        width: Int, height: Int, bounds: Rect, amount: Float,
        faceOutline: List<PointF>
    ) {
        val left = max(1, bounds.left).coerceAtMost(width - 1)
        val right = min(width - 1, bounds.right)
        val top = max(1, bounds.top).coerceAtMost(height - 1)
        val bottom = min(height - 1, bounds.bottom)
        val blend = amount.coerceIn(0f, 1f) * 0.28f
        if (left >= right || top >= bottom || blend <= 0f) return
        for (row in top until bottom) {
            val rowOffset = row * targetStride
            val sourceRow = row * sourceStride
            // The face oval is effectively convex for this mask. Calculate one
            // scanline span per row instead of testing every pixel against every
            // contour point (important on entry-level phones).
            var maskLeft = left
            var maskRight = right
            if (faceOutline.size >= 3) {
                var minX = Float.POSITIVE_INFINITY
                var maxX = Float.NEGATIVE_INFINITY
                var previous = faceOutline.last()
                for (point in faceOutline) {
                    if ((point.y > row) != (previous.y > row)) {
                        val crossX = point.x +
                            (previous.x - point.x) * (row - point.y) /
                            (previous.y - point.y)
                        minX = min(minX, crossX)
                        maxX = max(maxX, crossX)
                    }
                    previous = point
                }
                if (!minX.isFinite() || !maxX.isFinite()) continue
                maskLeft = max(left, minX.toInt())
                maskRight = min(right, maxX.toInt())
                if (maskLeft >= maskRight) continue
            }
            for (col in maskLeft until maskRight) {
                val index = rowOffset + col
                val chromaIndexU = (row / 2) * sourceUStride + (col / 2)
                val chromaIndexV = (row / 2) * sourceVStride + (col / 2)
                val u = sourceU.get(chromaIndexU).toInt() and 0xff
                val v = sourceV.get(chromaIndexV).toInt() and 0xff
                // Broad YUV skin-chroma gate avoids softening most background pixels,
                // clothing and high-contrast facial features.
                val skinMask = if (u in 65..145 && v in 125..195) 1f else 0.18f
                val centre = source.get(sourceRow + col).toInt() and 0xff
                val horizontal = ((source.get(sourceRow + col - 1).toInt() and 0xff) +
                    (source.get(sourceRow + col + 1).toInt() and 0xff)) * 0.5f
                val vertical = ((source.get(sourceRow - sourceStride + col).toInt() and 0xff) +
                    (source.get(sourceRow + sourceStride + col).toInt() and 0xff)) * 0.5f
                val localAverage = (centre * 0.5f) + (horizontal * 0.25f) + (vertical * 0.25f)
                val current = target.get(index).toInt() and 0xff
                val pixelBlend = blend * skinMask
                target.put(index, (current * (1f - pixelBlend) + localAverage * pixelBlend)
                    .toInt().coerceIn(0, 255).toByte())
            }
        }
    }

    private fun applyMakeup(
        u: ByteBuffer, uStride: Int, v: ByteBuffer, vStride: Int,
        width: Int, height: Int, landmarks: FaceLandmarkState,
        gender: Int, style: Int, intensity: Float
    ) {
        val bounds = landmarks.bounds
        val amount = intensity.coerceIn(0f, 1f)
        if (gender == 1) {
            val cheek = when (style) { 1 -> Pair(145f, 164f); 2 -> Pair(158f, 178f); else -> Pair(153f, 174f) }
            val radius = (bounds.width() * 0.105f).coerceAtLeast(5f) * 0.5f
            listOf(landmarks.leftCheek, landmarks.rightCheek).forEach { points ->
                if (points.isNotEmpty()) {
                    val cx = points.map { it.x }.average().toFloat() * 0.5f
                    val cy = points.map { it.y }.average().toFloat() * 0.5f
                    tintSoftCircle(u, uStride, v, vStride, width, height, cx, cy,
                        radius, cheek.first, cheek.second, amount * 0.48f)
                }
            }
            val lips = landmarks.upperLip + landmarks.lowerLip.asReversed()
            if (lips.size >= 6) {
                val polygon = lips.map { PointF(it.x * 0.5f, it.y * 0.5f) }
                val left = max(0, polygon.minOf { it.x }.toInt())
                val right = min(width - 1, polygon.maxOf { it.x }.toInt())
                val top = max(0, polygon.minOf { it.y }.toInt())
                val bottom = min(height - 1, polygon.maxOf { it.y }.toInt())
                val lip = when (style) { 1 -> Pair(151f, 166f); 2 -> Pair(166f, 190f); else -> Pair(160f, 181f) }
                for (row in top..bottom) for (col in left..right) {
                    if (insidePolygon(col.toFloat(), row.toFloat(), polygon))
                        blendChroma(u, uStride, v, vStride, col, row, lip.first, lip.second, amount * 0.62f)
                }
            }
        } else if (gender == 2 && landmarks.faceOutline.size >= 4) {
            val jaw = landmarks.faceOutline.filter { it.y >= bounds.top + bounds.height() * 0.52f }
            if (jaw.size >= 2) {
                val left = max(0, bounds.left / 2); val right = min(width - 1, bounds.right / 2)
                val top = max(0, (bounds.top + bounds.height() * 0.52f).toInt() / 2)
                val bottom = min(height - 1, bounds.bottom / 2)
                val tint = if (style == 2) Pair(119f, 139f) else Pair(124f, 137f)
                val radius = (bounds.width() * 0.018f).coerceAtLeast(2f)
                for (row in top..bottom) for (col in left..right) {
                    var nearest = Float.MAX_VALUE
                    for (i in 0 until jaw.lastIndex)
                        nearest = min(nearest, distanceToSegment(col * 2f, row * 2f, jaw[i], jaw[i + 1]))
                    if (nearest <= radius * 2f) {
                        val fade = (1f - nearest / (radius * 2f)).coerceIn(0f, 1f)
                        blendChroma(u, uStride, v, vStride, col, row, tint.first, tint.second, amount * 0.24f * fade)
                    }
                }
            }
        }
    }

    private fun tintSoftCircle(
        u: ByteBuffer, uStride: Int, v: ByteBuffer, vStride: Int,
        width: Int, height: Int, cx: Float, cy: Float, radius: Float,
        targetU: Float, targetV: Float, strength: Float
    ) {
        if (radius <= 0f) return
        val left = max(0, (cx - radius * 2).toInt()); val right = min(width - 1, (cx + radius * 2).toInt())
        val top = max(0, (cy - radius * 2).toInt()); val bottom = min(height - 1, (cy + radius * 2).toInt())
        for (row in top..bottom) for (col in left..right) {
            val distance = kotlin.math.sqrt(((col - cx) * (col - cx) + (row - cy) * (row - cy)).toDouble()).toFloat()
            val falloff = (1f - distance / (radius * 2f)).coerceIn(0f, 1f)
            val alpha = strength * falloff * falloff
            if (alpha > 0.005f) blendChroma(u, uStride, v, vStride, col, row, targetU, targetV, alpha)
        }
    }

    private fun blendChroma(
        u: ByteBuffer, uStride: Int, v: ByteBuffer, vStride: Int,
        x: Int, y: Int, targetU: Float, targetV: Float, alpha: Float
    ) {
        val ui = y * uStride + x; val vi = y * vStride + x
        val a = alpha.coerceIn(0f, 1f)
        val oldU = u.get(ui).toInt() and 0xff; val oldV = v.get(vi).toInt() and 0xff
        u.put(ui, (oldU * (1f - a) + targetU * a).toInt().coerceIn(0, 255).toByte())
        v.put(vi, (oldV * (1f - a) + targetV * a).toInt().coerceIn(0, 255).toByte())
    }

    private fun insidePolygon(x: Float, y: Float, points: List<PointF>): Boolean {
        var inside = false
        var j = points.lastIndex
        for (i in points.indices) {
            val a = points[i]; val b = points[j]
            if ((a.y > y) != (b.y > y) &&
                x < (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x) inside = !inside
            j = i
        }
        return inside
    }

    private fun distanceToSegment(x: Float, y: Float, a: PointF, b: PointF): Float {
        val dx = b.x - a.x; val dy = b.y - a.y
        val length2 = dx * dx + dy * dy
        if (length2 <= 0.0001f) return kotlin.math.sqrt(((x - a.x) * (x - a.x) + (y - a.y) * (y - a.y)).toDouble()).toFloat()
        val t = (((x - a.x) * dx + (y - a.y) * dy) / length2).coerceIn(0f, 1f)
        return kotlin.math.sqrt(((x - (a.x + t * dx)) * (x - (a.x + t * dx)) + (y - (a.y + t * dy)) * (y - (a.y + t * dy))).toDouble()).toFloat()
    }

    private fun applyColourGrade(
        plane: ByteBuffer, stride: Int, width: Int, height: Int,
        brightness: Float, contrast: Float
    ) {
        val offset = brightness * 255f
        for (row in 0 until height) {
            val rowOffset = row * stride
            for (col in 0 until width) {
                val index = rowOffset + col
                val value = plane.get(index).toInt() and 0xff
                val graded = ((value - 128f) * contrast + 128f + offset)
                    .toInt().coerceIn(0, 255)
                plane.put(index, graded.toByte())
            }
        }
    }

    private fun applyChromaGrade(
        uPlane: ByteBuffer, uStride: Int,
        vPlane: ByteBuffer, vStride: Int,
        width: Int, height: Int, saturation: Float, hue: Float, warmth: Float
    ) {
        val warmOffset = warmth * 18f
        val cosHue = kotlin.math.cos(hue.toDouble()).toFloat()
        val sinHue = kotlin.math.sin(hue.toDouble()).toFloat()
        for (row in 0 until height) {
            for (col in 0 until width) {
                val uIndex = row * uStride + col
                val vIndex = row * vStride + col
                val u = uPlane.get(uIndex).toInt() and 0xff
                val v = vPlane.get(vIndex).toInt() and 0xff
                val chromaU = (u - 128f) * saturation
                val chromaV = (v - 128f) * saturation
                val gradedU = (chromaU * cosHue - chromaV * sinHue + 128f - warmOffset)
                    .toInt().coerceIn(0, 255)
                val gradedV = (chromaU * sinHue + chromaV * cosHue + 128f + warmOffset)
                    .toInt().coerceIn(0, 255)
                uPlane.put(uIndex, gradedU.toByte())
                vPlane.put(vIndex, gradedV.toByte())
            }
        }
    }

    private fun warpPlane(
        src: ByteBuffer, srcStride: Int,
        dst: ByteBuffer, dstStride: Int,
        width: Int, height: Int,
        box: Rect, amount: Float
    ) {
        val left = max(0, box.left)
        val right = min(width, box.right)
        val top = max(0, box.top)
        val bottom = min(height, box.bottom)

        if (left >= right || top >= bottom) {
            for (row in 0 until height) {
                copyRowChunk(src, row * srcStride, dst, row * dstStride, width)
            }
            return
        }

        // 1. Fast native bulk copy for all rows above the face
        for (row in 0 until top) {
            copyRowChunk(src, row * srcStride, dst, row * dstStride, width)
        }

        val cx = (box.left + box.right) * 0.5f
        val cy = (box.top + box.bottom) * 0.5f
        val rx = max(1f, box.width() * 0.5f)
        val ry = max(1f, box.height() * 0.58f)
        val maxStrength = 0.18f
        val mirror = mirrorLeft

        // 2. Process rows within face vertical span
        for (row in top until bottom) {
            val srcRowOffset = row * srcStride
            val dstRowOffset = row * dstStride

            val dy = (row - cy) / ry
            val dy2 = dy * dy

            if (dy2 >= 1f) {
                copyRowChunk(src, srcRowOffset, dst, dstRowOffset, width)
                continue
            }

            val maxDx = kotlin.math.sqrt(1f - dy2) * rx
            val ellipseLeft = max(left, (cx - maxDx).toInt()).coerceIn(0, width)
            val ellipseRight = min(right, (cx + maxDx).toInt()).coerceIn(0, width)

            if (ellipseLeft >= ellipseRight) {
                copyRowChunk(src, srcRowOffset, dst, dstRowOffset, width)
                continue
            }

            // Bulk copy untouched slice to the left of the face contour
            if (ellipseLeft > 0) {
                copyRowChunk(src, srcRowOffset, dst, dstRowOffset, ellipseLeft)
            }

            // Anatomical vertical weighting (sculpt cheeks and jawline smoothly, keep forehead/eyes natural)
            val vWeight = if (row >= cy) {
                val progress = (row - cy) / max(1f, (bottom - cy).toFloat())
                1f - progress * 0.25f
            } else {
                val progress = (row - top) / max(1f, (cy - top).toFloat())
                progress * progress
            }

            // High-precision warp calculation strictly inside the facial ellipse
            for (col in ellipseLeft until ellipseRight) {
                val dx = (col - cx) / rx
                val radius2 = dx * dx + dy2
                var sx = col
                if (radius2 < 1f) {
                    val falloff = (1f - radius2) * (1f - radius2)
                    val dirWeight = when (mirror) {
                        true -> if (col > cx) 1.25f else 0.85f
                        false -> if (col < cx) 1.25f else 0.85f
                        null -> 1.0f
                    }
                    val compression = 1f - amount * maxStrength * falloff * vWeight * dirWeight
                    sx = (cx + (col - cx) / compression).toInt().coerceIn(0, width - 1)
                }
                dst.put(dstRowOffset + col, src.get(srcRowOffset + sx))
            }

            // Bulk copy untouched slice to the right of the face contour
            if (width > ellipseRight) {
                copyRowChunk(src, srcRowOffset + ellipseRight, dst, dstRowOffset + ellipseRight, width - ellipseRight)
            }
        }

        // 3. Fast native bulk copy for all rows below the face
        for (row in bottom until height) {
            copyRowChunk(src, row * srcStride, dst, row * dstStride, width)
        }
    }

    private fun copyRowChunk(
        src: ByteBuffer, srcOffset: Int,
        dst: ByteBuffer, dstOffset: Int,
        count: Int
    ) {
        if (count <= 0) return
        val buf = getTransferBuffer(count)
        src.position(srcOffset)
        src.get(buf, 0, count)
        dst.position(dstOffset)
        dst.put(buf, 0, count)
    }

    private fun getTransferBuffer(minSize: Int): ByteArray {
        if (transferBuffer.size < minSize) {
            transferBuffer = ByteArray(max(minSize, transferBuffer.size * 2))
        }
        return transferBuffer
    }

    private fun ensureUvCaches(halfW: Int) {
        if (uRowCache.size < halfW) {
            uRowCache = ByteArray(halfW)
            vRowCache = ByteArray(halfW)
            uvInterleavedCache = ByteArray(halfW * 2)
        }
    }

    private fun getOrCreateNv21(required: Int): ByteBuffer {
        val existing = cachedNv21
        return if (existing != null && cachedNv21Capacity >= required) {
            existing.clear()
            existing.limit(required)
            existing
        } else {
            val created = ByteBuffer.allocateDirect(required)
            cachedNv21 = created
            cachedNv21Capacity = required
            created
        }
    }

    private fun scale(rect: Rect, by: Float) = Rect(
        (rect.left * by).toInt(), (rect.top * by).toInt(),
        (rect.right * by).toInt(), (rect.bottom * by).toInt()
    )

    private fun blend(a: Int, b: Int) = (a * 0.72f + b * 0.28f).toInt()

    fun close() {
        closed = true
        cachedNv21 = null
        face = null
        faceLandmarks = null
        try {
            detector.close()
        } catch (_: Throwable) {}
    }
}
