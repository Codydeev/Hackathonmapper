package com.hackathonmapper.meshmapper

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.hackathonmapper.meshcore.DeviceUpdate
import com.hackathonmapper.meshcore.MeshCoreError
import com.hackathonmapper.meshcore.MeshJson
import com.hackathonmapper.meshcore.currentTime
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import java.io.IOException
import java.io.InputStream
import java.net.ConnectException
import java.net.HttpURLConnection
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.net.URI
import java.net.URISyntaxException
import java.net.URL
import java.net.UnknownHostException
import javax.net.ssl.SSLException
import kotlin.random.Random

/** Thrown for a base URL the gateway cannot use (Swift `URLError(.badURL)`). */
class GatewayURLException : IOException("The gateway URL is not a valid http:// or https:// address")

/** A response that is neither success nor a client error to pause on (Swift `URLError(.badServerResponse)`). */
class GatewayServerException(val statusCode: Int) : IOException("The dashboard answered HTTP $statusCode")

/**
 * The gateway's store of pending reports: the latest report per origin, capped at [capacity]
 * origins, removed only when exactly that report was uploaded. Not thread-safe; used on main.
 */
class GatewayPending(val capacity: Int = 100) {
    private val pending = HashMap<String, DeviceUpdate>()

    val count: Int get() = pending.size
    val isEmpty: Boolean get() = pending.isEmpty()

    /** A newer report replaces the pending one for its origin; new origins beyond the cap are dropped. */
    fun enqueue(devices: List<DeviceUpdate>) {
        for (device in devices) {
            if (pending.containsKey(device.id) || pending.size < capacity) pending[device.id] = device
        }
    }

    /** Pending reports sorted by device ID, as Swift snapshots them. */
    fun snapshot(): List<DeviceUpdate> = pending.values.sortedBy { it.id }

    /** Removes only entries still equal to what was sent; newer reports that arrived meanwhile stay. */
    fun removeSent(sent: List<DeviceUpdate>) {
        for (update in sent) if (pending[update.id] == update) pending.remove(update.id)
    }

    fun clear() = pending.clear()
}

/** `POST /api/updates` body (WEBSITE_PLAN.md), the same fields as Swift's `Batch`. */
@Serializable
data class GatewayBatch(
    val schemaVersion: Int = 1,
    val gatewayId: String,
    val frameId: String,
    val units: String = "m",
    val devices: List<DeviceUpdate>,
)

/** Splits pending reports into request bodies within the dashboard's limits. */
object GatewayBatching {
    const val maxDevices = 100
    const val maxBytes = 256 * 1024

    fun encode(batch: GatewayBatch): ByteArray =
        MeshJson.encodeToString(GatewayBatch.serializer(), batch).encodeToByteArray()

    /**
     * Consecutive batches of at most [maxDevices] devices and [maxBytes] encoded bytes, in input
     * order. The encoded size is exact: an empty batch plus each device's JSON and the commas between.
     * A device too large to fit any batch on its own is left out (validated reports never are).
     */
    fun split(
        devices: List<DeviceUpdate>,
        gatewayId: String,
        frameId: String,
        maxDevices: Int = GatewayBatching.maxDevices,
        maxBytes: Int = GatewayBatching.maxBytes,
    ): List<List<DeviceUpdate>> {
        val overhead = encode(GatewayBatch(gatewayId = gatewayId, frameId = frameId, devices = emptyList())).size
        val batches = mutableListOf<List<DeviceUpdate>>()
        var current = mutableListOf<DeviceUpdate>()
        var size = overhead
        for (device in devices) {
            val deviceSize = MeshJson.encodeToString(DeviceUpdate.serializer(), device).encodeToByteArray().size
            if (overhead + deviceSize > maxBytes) continue
            val added = deviceSize + if (current.isEmpty()) 0 else 1
            if (current.size >= maxDevices || size + added > maxBytes) {
                batches.add(current)
                current = mutableListOf()
                size = overhead
            }
            size += deviceSize + if (current.isEmpty()) 0 else 1
            current.add(device)
        }
        if (current.isNotEmpty()) batches.add(current)
        return batches
    }
}

/**
 * Uploads the latest report per device to the laptop (`POST /api/updates`) about once per
 * second, one request at a time, with HttpURLConnection on `Dispatchers.IO`. Observable state is
 * read and written on the main thread.
 */
class GatewayClient {
    var lastSuccess: Double? by mutableStateOf(null)
        private set
    var lastError: String? by mutableStateOf(null)
        private set
    var connectionStatus: String by mutableStateOf("Not checked")
        private set
    var pendingCount: Int by mutableStateOf(0)
        private set
    var enabled: Boolean by mutableStateOf(false)
        private set
    var acceptedCount: Int by mutableStateOf(0)
        private set
    var ignoredCount: Int by mutableStateOf(0)
        private set

    private val pending = GatewayPending()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var worker: Job? = null
    private var checkTask: Job? = null
    /** Bodies the dashboard refused with a 4xx; they are not resent until the data changes. */
    private var rejectedBodies: List<ByteArray> = emptyList()

    @Serializable
    private data class UploadResult(val accepted: Int, val ignored: Int)

    @Serializable
    private data class Health(val mode: String? = null)

    private class Response(val statusCode: Int, val body: ByteArray)

    companion object {
        /** Swift's `URLRequest.timeoutInterval = 3`. */
        const val timeoutMillis = 3_000
        const val maxDelay = 5.0

        private const val tokenRejected =
            "The dashboard refused the gateway token. Copy it again from `npm run tunnel` on the laptop."

        /**
         * Accepts what people actually paste: a missing `http://`, or the dashboard's full
         * `…/api/updates` URL, and reduces it to the base URL.
         */
        fun normalizedOrigin(origin: String): String {
            var text = origin.trim()
            if (text.isNotEmpty() && !text.contains("://")) text = "http://$text"
            for (suffix in listOf("/api/updates", "/api/health", "/api", "/")) {
                if (text.lowercase().endsWith(suffix)) text = text.dropLast(suffix.length)
            }
            return text
        }

        /** `<base>/<path>` for an http(s) base URL without credentials, query, fragment or path. */
        fun endpoint(origin: String, path: String): URL {
            val text = normalizedOrigin(origin)
            val uri = try {
                URI(text)
            } catch (_: URISyntaxException) {
                throw GatewayURLException()
            }
            val scheme = uri.scheme?.lowercase()
            if (scheme != "http" && scheme != "https") throw GatewayURLException()
            if (uri.host.isNullOrEmpty() || uri.rawUserInfo != null || uri.rawQuery != null || uri.rawFragment != null) {
                throw GatewayURLException()
            }
            val basePath = uri.rawPath ?: ""
            if (basePath.isNotEmpty() && basePath != "/") throw GatewayURLException()
            return try {
                URL(text.trimEnd('/') + "/" + path)
            } catch (_: Exception) {
                throw GatewayURLException()
            }
        }

        /** Readable text for an upload failure, like `URLError.localizedDescription`. */
        fun describe(error: Throwable): String = when (error) {
            is GatewayURLException, is GatewayServerException -> error.message ?: "Upload failed"
            is SocketTimeoutException -> "The request timed out."
            is UnknownHostException -> "A server with the specified hostname could not be found."
            is ConnectException, is NoRouteToHostException -> "Could not connect to the server."
            is SSLException -> "A secure connection to the server could not be made."
            is MeshCoreError.invalidUpdate -> "A pending report breaks the dashboard limits; it is held back."
            is MeshCoreError -> "Invalid pending report (${error::class.simpleName})."
            else -> error.message ?: error::class.java.simpleName
        }

        private fun readAll(stream: InputStream?, limit: Int): ByteArray {
            stream ?: return ByteArray(0)
            stream.use { input ->
                val out = java.io.ByteArrayOutputStream()
                val buffer = ByteArray(8_192)
                while (out.size() < limit) {
                    val read = input.read(buffer, 0, minOf(buffer.size, limit - out.size()))
                    if (read < 0) break
                    out.write(buffer, 0, read)
                }
                return out.toByteArray()
            }
        }
    }

    // Required only by the internet (tunnel) endpoint; the LAN server ignores the header.
    private fun authorize(connection: HttpURLConnection, token: String) {
        val trimmed = token.trim()
        if (trimmed.isNotEmpty()) connection.setRequestProperty("Authorization", "Bearer $trimmed")
    }

    /** One blocking HTTP exchange on the IO dispatcher; both timeouts are about three seconds. */
    private suspend fun perform(url: URL, token: String, body: ByteArray? = null): Response =
        withContext(Dispatchers.IO) {
            val connection = url.openConnection() as HttpURLConnection
            try {
                connection.connectTimeout = timeoutMillis
                connection.readTimeout = timeoutMillis
                connection.useCaches = false
                connection.instanceFollowRedirects = false
                connection.setRequestProperty("Accept", "application/json")
                authorize(connection, token)
                if (body != null) {
                    connection.requestMethod = "POST"
                    connection.doOutput = true
                    connection.setRequestProperty("Content-Type", "application/json")
                    connection.setFixedLengthStreamingMode(body.size)
                    connection.outputStream.use { it.write(body) }
                } else {
                    connection.requestMethod = "GET"
                }
                val status = connection.responseCode
                val stream = if (status >= 400) connection.errorStream else connection.inputStream
                Response(status, readAll(stream, 64 * 1024))
            } finally {
                connection.disconnect()
            }
        }

    fun checkConnection(origin: String, token: String) {
        checkTask?.cancel()
        connectionStatus = "Checking…"
        checkTask = scope.launch {
            try {
                val response = perform(endpoint(origin, "api/health"), token)
                ensureActive()
                if (response.statusCode == 401) {
                    connectionStatus = "Token rejected"
                    lastError = tokenRejected
                    return@launch
                }
                if (response.statusCode !in 200..299) throw GatewayServerException(response.statusCode)
                val mode = try {
                    MeshJson.decodeFromString(Health.serializer(), response.body.decodeToString()).mode
                } catch (_: Exception) {
                    null
                }
                connectionStatus = if (mode == "simulated") {
                    "Reachable, but the dashboard shows simulated data (switch it to Live)"
                } else {
                    "Dashboard reachable"
                }
                lastError = null
            } catch (cancel: CancellationException) {
                throw cancel
            } catch (error: Exception) {
                connectionStatus = "Connection failed"
                lastError = describe(error)
            }
        }
    }

    fun enqueue(devices: List<DeviceUpdate>) {
        pending.enqueue(devices)
        pendingCount = pending.count
    }

    fun start(origin: String, gatewayId: String, frameId: String, token: String) {
        val previous = worker
        stop()
        enabled = true
        rejectedBodies = emptyList()
        worker = scope.launch {
            // A cancelled worker may still be blocked in a request; keep one request in flight.
            previous?.join()
            var delaySeconds = 1.0
            while (true) {
                ensureActive()
                if (!pending.isEmpty) {
                    val snapshot = pending.snapshot()
                    try {
                        for (update in snapshot) update.validate()
                        val url = endpoint(origin, "api/updates")
                        val stillRejected = mutableListOf<ByteArray>()
                        for (devices in GatewayBatching.split(snapshot, gatewayId, frameId)) {
                            val body = GatewayBatching.encode(
                                GatewayBatch(gatewayId = gatewayId, frameId = frameId, devices = devices))
                            if (rejectedBodies.any { it.contentEquals(body) }) {
                                stillRejected.add(body)
                                continue
                            }
                            val response = perform(url, token, body)
                            ensureActive()
                            val status = response.statusCode
                            if (status == 401) {
                                // Retrying cannot fix a wrong token; stop until it is corrected.
                                lastError = tokenRejected
                                stop()
                                return@launch
                            }
                            if (status in 200..299) {
                                pending.removeSent(devices)
                                pendingCount = pending.count
                                try {
                                    val result = MeshJson.decodeFromString(UploadResult.serializer(), response.body.decodeToString())
                                    acceptedCount += result.accepted
                                    ignoredCount += result.ignored
                                } catch (_: Exception) {
                                }
                                lastSuccess = currentTime()
                                lastError = null
                                delaySeconds = 1.0
                            } else if (status in 400..499 && status != 408 && status != 429) {
                                // 400 validation or 409 mode/frame conflict: pause this batch until it changes.
                                stillRejected.add(body)
                                val text = response.body.copyOf(minOf(512, response.body.size)).decodeToString()
                                lastError = "HTTP $status: $text. Correct the data/frame or restart gateway."
                                delaySeconds = 1.0
                            } else {
                                throw GatewayServerException(status)
                            }
                        }
                        rejectedBodies = stillRejected
                    } catch (cancel: CancellationException) {
                        throw cancel
                    } catch (error: Exception) {
                        lastError = describe(error)
                        delaySeconds = minOf(maxDelay, delaySeconds * 2)
                    }
                }
                // Jitter only while backing off, so gateways retrying a dead laptop don't align.
                val wait = if (delaySeconds > 1.0) minOf(maxDelay, delaySeconds * Random.nextDouble(0.75, 1.25)) else delaySeconds
                delay((wait * 1000).toLong())
            }
        }
    }

    fun stop() {
        worker?.cancel()
        worker = null
        if (checkTask?.isActive == true) {
            // A cancelled check never answered; don't leave "Checking…" on screen.
            connectionStatus = "Not checked"
        }
        checkTask?.cancel()
        checkTask = null
        enabled = false
    }

    fun reset() {
        stop()
        pending.clear()
        pendingCount = 0
        rejectedBodies = emptyList()
        acceptedCount = 0
        ignoredCount = 0
        lastSuccess = null
        lastError = null
    }
}
