package org.findmyfam

import org.findmyfam.services.MLSService
import org.junit.Assert.*
import org.junit.Test

/**
 * Tests for the plaintext-SQLite detection that guards the delete-and-recreate
 * path in MLSService.initialise().
 *
 * The guard exists so a healthy *encrypted* DB that merely fails to open (e.g.
 * transient Keystore unavailability on a background launch) is never wiped —
 * only a genuine pre-encryption plaintext DB is recreated. See bug: "TestFlight
 * update overwrote group membership".
 */
class MLSServiceTest {

    private val sqliteMagic = byteArrayOf(
        0x53, 0x51, 0x4C, 0x69, 0x74, 0x65, 0x20, 0x66,
        0x6F, 0x72, 0x6D, 0x61, 0x74, 0x20, 0x33, 0x00
    )

    @Test
    fun plaintextSqliteHeader_recognised() {
        assertTrue(MLSService.isPlaintextSqliteHeader(sqliteMagic))
    }

    @Test
    fun plaintextSqliteHeader_recognised_withTrailingBytes() {
        // Real DB files have more bytes after the 16-byte magic.
        val full = sqliteMagic + ByteArray(100) { 0x42 }
        assertTrue(MLSService.isPlaintextSqliteHeader(full))
    }

    @Test
    fun encryptedHeader_notRecognised() {
        // SQLCipher encrypts the header, so it never carries the SQLite magic.
        val encrypted = ByteArray(16) { (it * 7 + 3).toByte() }
        assertFalse(MLSService.isPlaintextSqliteHeader(encrypted))
    }

    @Test
    fun shortHeader_notRecognised() {
        assertFalse(MLSService.isPlaintextSqliteHeader(byteArrayOf(0x53, 0x51, 0x4C)))
    }

    @Test
    fun emptyHeader_notRecognised() {
        assertFalse(MLSService.isPlaintextSqliteHeader(ByteArray(0)))
    }
}
