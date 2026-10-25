package com.hackathonmapper.meshcore

import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.random.Random

/**
 * Retry schedule for a failed outgoing BLE link: 5, 10, 20, 40, then 60 s, plus up to 2 s of
 * jitter so neighbors that lost each other at the same moment don't retry in lockstep. A link that
 * stayed ready for `stableLinkAge` clears its failure count.
 */
object ReconnectBackoff {
    const val initialDelay: TimeInterval = 5.0
    const val maximumDelay: TimeInterval = 60.0
    const val maximumJitter: TimeInterval = 2.0
    const val stableLinkAge: TimeInterval = 30.0

    /** Delay before the next attempt after `failures` consecutive failures (1 for the first). */
    fun delay(afterFailures: Int, jitter: TimeInterval = Random.nextDouble(0.0, maximumJitter)): TimeInterval {
        val exponent = (min(max(afterFailures, 1), 16) - 1).toDouble()
        return min(maximumDelay, initialDelay * 2.0.pow(exponent)) + min(max(jitter, 0.0), maximumJitter)
    }
}
