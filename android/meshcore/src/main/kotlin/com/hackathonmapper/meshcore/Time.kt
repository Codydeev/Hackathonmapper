package com.hackathonmapper.meshcore

/**
 * Swift's `Date` maps to seconds since the Unix epoch as a Double, and
 * `TimeInterval` to Double seconds. Every `at now: Date = Date()` parameter
 * becomes `now: Double = currentTime()`.
 */
typealias TimeInterval = Double

fun currentTime(): Double = System.currentTimeMillis() / 1000.0
