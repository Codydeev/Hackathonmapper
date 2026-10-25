package com.hackathonmapper.meshmapper

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The cloud dots must come out the same as Swift's `SplitMix64` and `Double.random(in: 0..<1, using:)`. */
class SplitMix64Tests {
    @Test
    fun referenceVectors() {
        val zero = SplitMix64(0uL)
        assertEquals(0xE220A8397B1DCDAFuL, zero.next())
        assertEquals(0x6E789E6AA1B965F4uL, zero.next())
        assertEquals(0x06C45D188009454FuL, zero.next())

        val seeded = SplitMix64(1234567uL)
        val expected = listOf(
            6457827717110365317uL, 3203168211198807973uL, 9817491932198370423uL,
            4593380528125082431uL, 16408922859458223821uL,
        )
        for (value in expected) assertEquals(value, seeded.next())
    }

    @Test
    fun unitValuesUseTheLow53Bits() {
        val a = SplitMix64(7uL)
        val b = SplitMix64(7uL)
        repeat(1000) {
            val raw = b.next()
            val unit = a.nextUnit()
            assertEquals((raw and ((1uL shl 53) - 1uL)).toLong().toDouble() / 9007199254740992.0, unit, 0.0)
            assertTrue(unit >= 0.0 && unit < 1.0)
        }
    }

    @Test
    fun sameSeedSameDots() {
        val seed = "3F2504E0-4F89-11D3-9A0C-0305E82C3301".hashCode().toLong().toULong()
        val first = SplitMix64(seed).let { g -> (0 until 5).map { g.next() } }
        val second = SplitMix64(seed).let { g -> (0 until 5).map { g.next() } }
        assertEquals(first, second)
    }
}
