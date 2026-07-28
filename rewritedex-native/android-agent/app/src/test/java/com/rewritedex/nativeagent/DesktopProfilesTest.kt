package com.rewritedex.nativeagent

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DesktopProfilesTest {
    @Test
    fun normalizedBoundsFollowDisplayResize() {
        val encoded = DesktopBounds.encodeNormalized(200, 100, 1200, 800, 2000, 1000)
        assertEquals(
            ParsedTaskBounds(100, 50, 600, 400),
            DesktopBounds.decodeNormalizedValues(encoded, 1000, 500),
        )
    }

    @Test
    fun presetsRemainInsideDisplay() {
        DesktopProfile.entries.forEach { profile ->
            val bounds = DesktopBounds.calculate(profile, 1920, 1008, 231)
            assertTrue(bounds.left >= 0 && bounds.top >= 0)
            assertTrue(bounds.right <= 1920 && bounds.bottom <= 1008)
        }
    }

    @Test
    fun scaleAboutCenterStaysOnDisplay() {
        val smaller = DesktopBounds.scaleAboutCenter(400, 200, 1200, 800, 1920, 1080, 0.82f)
        assertTrue(smaller.right - smaller.left < 800)
        assertTrue(smaller.bottom - smaller.top < 600)
        assertTrue(smaller.left >= 0 && smaller.top >= 0)
        assertTrue(smaller.right <= 1920 && smaller.bottom <= 1080)
        val larger = DesktopBounds.scaleAboutCenter(400, 200, 1200, 800, 1920, 1080, 1.22f)
        assertTrue(larger.right - larger.left > 800)
        assertTrue(larger.right <= 1920 && larger.bottom <= 1080)
    }
}
