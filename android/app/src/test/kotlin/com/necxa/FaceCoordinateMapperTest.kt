package com.necxa

import org.junit.Assert.assertEquals
import org.junit.Test

class FaceCoordinateMapperTest {
    @Test fun rotationZeroKeepsCoordinates() {
        assertEquals(FramePoint(12f, 34f), FaceCoordinateMapper.mapPoint(12f, 34f, 100, 200, 0))
    }

    @Test fun clockwiseNinetyMapsBackToRawBuffer() {
        assertEquals(FramePoint(12f, 166f), FaceCoordinateMapper.mapPoint(34f, 12f, 100, 200, 90))
    }

    @Test fun halfTurnMapsBackToRawBuffer() {
        assertEquals(FramePoint(88f, 166f), FaceCoordinateMapper.mapPoint(12f, 34f, 100, 200, 180))
    }

    @Test fun clockwiseTwoSeventyMapsBackToRawBuffer() {
        assertEquals(FramePoint(88f, 34f), FaceCoordinateMapper.mapPoint(34f, 12f, 100, 200, 270))
    }

    @Test fun rotatedRectIsClampedToRawFrame() {
        val rect = FaceCoordinateMapper.mapRect(10, 20, 60, 80, 100, 200, 90)
        assertEquals(FrameRect(20, 140, 80, 190), rect)
    }
}
