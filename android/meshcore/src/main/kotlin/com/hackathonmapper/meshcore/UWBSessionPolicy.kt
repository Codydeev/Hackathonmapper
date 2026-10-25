package com.hackathonmapper.meshcore

import kotlin.math.max

/** A linked neighbor this phone could run a UWB session with. */
data class UWBPeerCandidate(
    val id: String,
    /** Mean RSSI of the pair, from both ends where known. */
    val rssi: Double? = null,
    /** One end of the link is a mounted direction anchor. */
    val isDirectionAnchor: Boolean = false,
    /** One end of the link reports `positionSource == none`. */
    val touchesUnplaced: Boolean = false,
    /**
     * When the current session started measuring, or was opened while it still swaps tokens; null
     * without a session. A session younger than `minHold` keeps its slot. Unix seconds (Swift `Date`).
     */
    val measuringSince: Double? = null,
) {
    /** Lower is more important: direction anchor, then a link to an unplaced phone, then the rest. */
    internal val rankClass: Int get() = if (isDirectionAnchor) 0 else if (touchesUnplaced) 1 else 2
}

/**
 * Chooses which neighbors get one of the phone's few concurrent Nearby Interaction sessions.
 * Both ends rank from the same shared mesh reports, so they usually choose each other.
 */
object UWBSessionPolicy {
    /** Sessions per phone until iOS refuses one. */
    const val initialBudget = 4

    /** The budget after `activeSessionsLimitExceeded` with `active` sessions running (counting the refused one). */
    fun reducedBudget(active: Int): Int = max(1, active - 1)

    /**
     * Keeps the best `budget` candidates by rank class, then stronger RSSI (ties by ID). A session
     * that started measuring less than `minHold` ago keeps its slot, displacing the lowest-ranked
     * newcomer of the same or a lower class; only a higher-class candidate can push it out.
     */
    fun select(c: List<UWBPeerCandidate>, budget: Int, now: Double, minHold: TimeInterval = 20.0): Set<String> {
        val seen = HashSet<String>()
        val unique = c.filter { seen.add(it.id) }
        val ranked = unique.sortedWith { a, b ->
            if (a.rankClass != b.rankClass) return@sortedWith a.rankClass.compareTo(b.rankClass)
            val ra = a.rssi ?: Double.NEGATIVE_INFINITY
            val rb = b.rssi ?: Double.NEGATIVE_INFINITY
            if (ra != rb) return@sortedWith if (ra > rb) -1 else 1
            a.id.compareTo(b.id)
        }
        val isHeld = { candidate: UWBPeerCandidate ->
            val since = candidate.measuringSince
            since != null && now - since < minHold
        }
        val chosen = ranked.take(max(0, budget)).toMutableList()
        for (held in ranked) {
            if (!isHeld(held) || chosen.any { it.id == held.id }) continue
            val index = chosen.indexOfLast { !isHeld(it) && it.rankClass >= held.rankClass }
            if (index < 0) continue
            chosen.removeAt(index)
            chosen.add(held)
        }
        return chosen.map { it.id }.toSet()
    }
}
