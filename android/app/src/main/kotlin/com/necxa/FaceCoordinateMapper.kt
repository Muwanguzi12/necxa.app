package com.necxa

internal data class FramePoint(val x: Float, val y: Float)
internal data class FrameRect(val left: Int, val top: Int, val right: Int, val bottom: Int)

/**
 * ML Kit reports points in the rotation-corrected image coordinate space.
 * These helpers map them back into the unrotated I420 buffer coordinates.
 */
internal object FaceCoordinateMapper {
    fun mapPoint(x: Float, y: Float, width: Int, height: Int, rotation: Int): FramePoint =
        when (((rotation % 360) + 360) % 360) {
            90 -> FramePoint(y, height - x)
            180 -> FramePoint(width - x, height - y)
            270 -> FramePoint(width - y, x)
            else -> FramePoint(x, y)
        }

    fun mapRect(
        left: Int, top: Int, right: Int, bottom: Int,
        width: Int, height: Int, rotation: Int
    ): FrameRect {
        val corners = listOf(
            mapPoint(left.toFloat(), top.toFloat(), width, height, rotation),
            mapPoint(right.toFloat(), top.toFloat(), width, height, rotation),
            mapPoint(left.toFloat(), bottom.toFloat(), width, height, rotation),
            mapPoint(right.toFloat(), bottom.toFloat(), width, height, rotation)
        )
        return FrameRect(
            corners.minOf { it.x }.toInt().coerceIn(0, width),
            corners.minOf { it.y }.toInt().coerceIn(0, height),
            corners.maxOf { it.x }.toInt().coerceIn(0, width),
            corners.maxOf { it.y }.toInt().coerceIn(0, height)
        )
    }
}
