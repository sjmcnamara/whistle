package org.findmyfam

import org.findmyfam.viewmodels.LatLon
import org.findmyfam.viewmodels.MemberAnnotation
import org.junit.Assert.*
import org.junit.Test

/**
 * Tests for the MemberAnnotation and LatLon data classes.
 */
class MemberAnnotationTest {

    @Test
    fun latLon_equality() {
        val a = LatLon(53.3498, -6.2603)
        val b = LatLon(53.3498, -6.2603)
        assertEquals(a, b)
    }

    @Test
    fun latLon_inequality() {
        val a = LatLon(53.3498, -6.2603)
        val b = LatLon(53.3499, -6.2603)
        assertNotEquals(a, b)
    }

    @Test
    fun memberAnnotation_defaultValues() {
        val annotation = MemberAnnotation(
            id = "group:pubkey",
            position = LatLon(53.3498, -6.2603),
            displayName = "Alice",
            isStale = false,
            timestampMs = 1000000L,
            isMe = false
        )
        assertEquals("Alice", annotation.displayName)
        assertFalse(annotation.isStale)
        assertFalse(annotation.isMe)
    }

    @Test
    fun memberAnnotation_staleFlag() {
        val annotation = MemberAnnotation(
            id = "id",
            position = LatLon(0.0, 0.0),
            displayName = "Bob",
            isStale = true,
            timestampMs = 0L,
            isMe = false
        )
        assertTrue(annotation.isStale)
    }

    @Test
    fun memberAnnotation_meFlag() {
        val annotation = MemberAnnotation(
            id = "id",
            position = LatLon(0.0, 0.0),
            displayName = "Me",
            isStale = false,
            timestampMs = 0L,
            isMe = true
        )
        assertTrue(annotation.isMe)
    }

    @Test
    fun memberAnnotation_equality() {
        val a = MemberAnnotation("id", LatLon(1.0, 2.0), "Name", false, 100L, true)
        val b = MemberAnnotation("id", LatLon(1.0, 2.0), "Name", false, 100L, true)
        assertEquals(a, b)
    }

    @Test
    fun memberAnnotation_copy() {
        val original = MemberAnnotation("id", LatLon(1.0, 2.0), "Old", false, 100L, false)
        val updated = original.copy(displayName = "New")
        assertEquals("Old", original.displayName)
        assertEquals("New", updated.displayName)
    }
}
