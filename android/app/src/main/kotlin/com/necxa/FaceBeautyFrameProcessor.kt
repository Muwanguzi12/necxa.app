package com.necxa

import android.graphics.Rect
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetector
import com.google.mlkit.vision.face.FaceDetectorOptions
import com.cloudwebrtc.webrtc.video.LocalVideoTrack
import org.webrtc.JavaI420Buffer
import org.webrtc.VideoFrame
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max
import kotlin.math.min

/** Device-side, fail-open face contour warp for the local camera track. */
internal class FaceBeautyFrameProcessor : LocalVideoTrack.ExternalVideoFrameProcessing {
    @Volatile var intensity: Float = 0.35f
    private val detector: FaceDetector = FaceDetection.getClient(
        FaceDetectorOptions.Builder()
            .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_FAST)
            .setLandmarkMode(FaceDetectorOptions.LANDMARK_MODE_NONE)
            .setClassificationMode(FaceDetectorOptions.CLASSIFICATION_MODE_NONE)
            .setContourMode(FaceDetectorOptions.CONTOUR_MODE_ALL)
            .setMinFaceSize(0.15f)
            .build()
    )
    private val detecting = AtomicBoolean(false)
    @Volatile private var face: Rect? = null
    private var frameCount = 0
    @Volatile private var closed = false

    override fun onFrame(frame: VideoFrame): VideoFrame {
        if (closed) return frame
        return try {
            val source = frame.buffer.toI420() ?: return frame
            try {
                frameCount++
                if (frameCount % 8 == 0 && detecting.compareAndSet(false, true)) {
                    detect(source, frame.rotation)
                }
                val bounds = face
                val amount = intensity.coerceIn(0f, 0.65f)
                if (bounds == null || amount <= 0f) return frame
                val output = JavaI420Buffer.allocate(source.width, source.height)
                warpPlane(source.dataY, source.strideY, output.dataY, output.strideY,
                    source.width, source.height, bounds, amount)
                warpPlane(source.dataU, source.strideU, output.dataU, output.strideU,
                    source.width / 2, source.height / 2, scale(bounds, 0.5f), amount)
                warpPlane(source.dataV, source.strideV, output.dataV, output.strideV,
                    source.width / 2, source.height / 2, scale(bounds, 0.5f), amount)
                VideoFrame(output, frame.rotation, frame.timestampNs)
            } finally {
                source.release()
            }
        } catch (_: Throwable) {
            frame
        }
    }

    private fun detect(buffer: org.webrtc.VideoFrame.I420Buffer, rotation: Int) {
        try {
            val w = buffer.width
            val h = buffer.height
            val nv21 = ByteBuffer.allocateDirect(w * h * 3 / 2)
            val y = buffer.dataY
            for (row in 0 until h) for (col in 0 until w) nv21.put(y.get(row * buffer.strideY + col))
            val u = buffer.dataU
            val v = buffer.dataV
            for (row in 0 until h / 2) for (col in 0 until w / 2) {
                nv21.put(v.get(row * buffer.strideV + col))
                nv21.put(u.get(row * buffer.strideU + col))
            }
            nv21.flip()
            val image = InputImage.fromByteBuffer(nv21, w, h, rotation, InputImage.IMAGE_FORMAT_NV21)
            detector.process(image)
                .addOnSuccessListener { faces ->
                    val next = faces.maxByOrNull { it.boundingBox.width() * it.boundingBox.height() }?.boundingBox
                    if (next == null) face = null else {
                        val old = face
                        face = if (old == null) Rect(next) else Rect(
                            blend(old.left, next.left), blend(old.top, next.top),
                            blend(old.right, next.right), blend(old.bottom, next.bottom)
                        )
                    }
                }
                .addOnFailureListener { face = null }
                .addOnCompleteListener { detecting.set(false) }
        } catch (_: Throwable) {
            detecting.set(false)
        }
    }

    private fun warpPlane(src: ByteBuffer, srcStride: Int, dst: ByteBuffer, dstStride: Int,
                          width: Int, height: Int, box: Rect, amount: Float) {
        val left = max(0, box.left); val right = min(width, box.right)
        val top = max(0, box.top); val bottom = min(height, box.bottom)
        val cx = (box.left + box.right) * 0.5f
        val cy = (box.top + box.bottom) * 0.5f
        val rx = max(1f, (box.width() * 0.5f))
        val ry = max(1f, box.height() * 0.58f)
        for (row in 0 until height) for (col in 0 until width) {
            var sx = col
            if (col in left until right && row in top until bottom) {
                val dx = (col - cx) / rx
                val dy = (row - cy) / ry
                val radius = dx * dx + dy * dy
                if (radius < 1f) {
                    val falloff = (1f - radius) * (1f - radius)
                    val compression = 1f - amount * 0.10f * falloff
                    sx = (cx + (col - cx) / compression).toInt().coerceIn(0, width - 1)
                }
            }
            dst.put(row * dstStride + col, src.get(row * srcStride + sx))
        }
    }

    private fun scale(rect: Rect, by: Float) = Rect(
        (rect.left * by).toInt(), (rect.top * by).toInt(),
        (rect.right * by).toInt(), (rect.bottom * by).toInt()
    )

    private fun blend(a: Int, b: Int) = (a * 0.72f + b * 0.28f).toInt()

    fun close() { closed = true; detector.close() }
}
