package com.hackathonmapper.meshmapper

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelUuid
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import com.hackathonmapper.meshcore.AmbientAdvertisement
import com.hackathonmapper.meshcore.AmbientEmitterKey
import com.hackathonmapper.meshcore.AmbientRecorder
import com.hackathonmapper.meshcore.AmbientSnapshot
import com.hackathonmapper.meshcore.FingerprintDatabase
import com.hackathonmapper.meshcore.RadioFingerprint
import com.hackathonmapper.meshcore.TimeInterval
import com.hackathonmapper.meshcore.currentTime
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.File
import java.util.Locale
import java.util.UUID

/**
 * Experimental passive scan of every Bluetooth LE advertisement in range, for ambient radio
 * fingerprinting (docs/AMBIENT_RADIO.md). It never connects, so the mesh's discovery, links and
 * relaying are left alone; it runs only while `AmbientRadioView` is open and the user has started
 * it, and the view stops it when the app leaves the foreground (Swift observes
 * `didEnterBackgroundNotification` itself). The devices it hears are observations, never peers,
 * relays or anchors.
 *
 * Android scan limits, and why this is a second scan rather than part of `BluetoothMesh`'s:
 * - The mesh scan filters on the mesh service UUID, which lets it keep running with the screen
 *   off; an unfiltered scan does not (Android pauses those while the screen is off), so merging the
 *   two would weaken the mesh. Swift likewise uses a second central manager.
 * - One app may run several scans at once (each `ScanCallback` is its own scanner client), but
 *   every app is allowed at most 5 scan starts per 30 s across all of them. This one starts only
 *   when the user turns it on. If the stack refuses it (`SCAN_FAILED_SCANNING_TOO_FREQUENTLY` or
 *   any other error) it is retried after [scanRetryDelay] while the user still wants it.
 * - Both scans share the radio, so listening may slow mesh link-up (not measured; ARCHITECTURE.md
 *   T1), exactly as on iOS.
 *
 * Android has no Core Bluetooth peripheral identifier: the emitter's identity is its (usually
 * random, rotating) BLE address, digested by `AmbientEmitterKey` like iOS's identifier and, like
 * it, meaningful only on this phone. Service UUIDs are written the way `CBUUID.uuidString` writes
 * them ("FEAA" for a 16-bit UUID) and manufacturer data gets its 2-byte company ID back in front, so
 * advertisement classes and Eddystone keys digest the same on both platforms.
 *
 * Scan callbacks arrive on the main looper; the recorder sits behind a lock (Swift's `Buffer`) so
 * the advertisement path stays cheap and thread-agnostic.
 */
class AmbientRadioScanner(context: Context) {
    companion object {
        /** How much is kept: enough for a 20 s recording plus slack. */
        const val horizon: TimeInterval = 120.0
        /** After a refused scan start, wait this long before trying again. */
        const val scanRetryDelay: TimeInterval = 30.0

        /** Swift `CBUUID.uuidString`: 16- and 32-bit Bluetooth base UUIDs in short form, all uppercase. */
        fun uuidString(uuid: ParcelUuid): String = uuidString(uuid.uuid)

        fun uuidString(uuid: UUID): String {
            val text = uuid.toString().uppercase(Locale.US)
            if (!text.endsWith("-0000-1000-8000-00805F9B34FB")) return text
            val head = text.substring(0, 8)
            return if (head.startsWith("0000")) head.substring(4) else head
        }

        /** Swift's manufacturer data: the 2-byte company ID, little endian, then the payload. */
        fun manufacturerData(companyId: Int, payload: ByteArray): ByteArray =
            byteArrayOf((companyId and 0xFF).toByte(), ((companyId shr 8) and 0xFF).toByte()) + payload
    }

    var isScanning: Boolean by mutableStateOf(false)
        private set
    var bluetoothState: BluetoothState by mutableStateOf(BluetoothState.unknown)
        private set
    /** Devices (not GhostCore peers) heard in the last `horizon` seconds. */
    var devicesHeard: Int by mutableStateOf(0)
        private set
    /** When the current scan started, Unix seconds. */
    var startedAt: Double? by mutableStateOf(null)
        private set

    /** Swift's view checks `bluetoothState` for `.unauthorized`, `.poweredOff`, `.unsupported`. */
    val bluetoothUnavailable: Boolean
        get() = bluetoothState == BluetoothState.unauthorized || bluetoothState == BluetoothState.poweredOff ||
            bluetoothState == BluetoothState.unsupported

    private val appContext = context.applicationContext
    private val adapter: BluetoothAdapter? =
        (appContext.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager?)?.adapter
    private val buffer = Buffer(setOf(BluetoothMesh.serviceID.toString().uppercase(Locale.US)))
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var timer: Job? = null
    private var scanFailedAt: Double? = null

    fun start() {
        if (buffer.wantsScan) return
        buffer.wantsScan = true
        buffer.clear()
        startedAt = currentTime()
        scan()
        timer?.cancel()
        timer = scope.launch {
            while (isActive) {
                delay(1_000)
                refresh()
            }
        }
    }

    @SuppressLint("MissingPermission") // canScan is checked; SecurityException is caught.
    fun stop() {
        buffer.wantsScan = false
        if (isScanning) {
            try {
                if (canScan) adapter?.bluetoothLeScanner?.stopScan(callback)
            } catch (_: SecurityException) {
            } catch (_: IllegalStateException) {
            }
        }
        timer?.cancel()
        timer = null
        scanFailedAt = null
        isScanning = false
        startedAt = null
    }

    /** Seconds of listening so far in this scan. */
    val listenedFor: TimeInterval get() = startedAt?.let { currentTime() - it } ?: 0.0

    /** What was heard over the last `seconds`. */
    fun snapshot(seconds: TimeInterval): AmbientSnapshot {
        val now = currentTime()
        return buffer.snapshot(now - seconds, now)
    }

    private fun refresh() {
        devicesHeard = buffer.deviceCount(currentTime())
        // Retry a refused start, and pick the scan up again when Bluetooth comes back on.
        val failedAt = scanFailedAt
        val retry = failedAt == null || currentTime() - failedAt >= scanRetryDelay
        if (buffer.wantsScan && !isScanning && retry) scan() else updateState()
    }

    private val canScan: Boolean
        get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) granted(Manifest.permission.BLUETOOTH_SCAN)
        else granted(Manifest.permission.ACCESS_FINE_LOCATION)

    private fun granted(permission: String): Boolean =
        ContextCompat.checkSelfPermission(appContext, permission) == PackageManager.PERMISSION_GRANTED

    private fun updateState() {
        val state = when {
            adapter == null || !appContext.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE) ->
                BluetoothState.unsupported
            !canScan -> BluetoothState.unauthorized
            else -> when (adapter.state) {
                BluetoothAdapter.STATE_ON -> BluetoothState.poweredOn
                BluetoothAdapter.STATE_OFF -> BluetoothState.poweredOff
                BluetoothAdapter.STATE_TURNING_ON, BluetoothAdapter.STATE_TURNING_OFF -> BluetoothState.resetting
                else -> BluetoothState.unknown
            }
        }
        if (state != bluetoothState) bluetoothState = state
        if (state != BluetoothState.poweredOn && isScanning) isScanning = false
    }

    @SuppressLint("MissingPermission")
    private fun scan() {
        updateState()
        if (bluetoothState != BluetoothState.poweredOn || !buffer.wantsScan || isScanning) return
        val scanner = adapter?.bluetoothLeScanner ?: return
        // Every service, every advertisement: one RSSI per advertisement, foreground only.
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
            .setReportDelay(0)
            .build()
        isScanning = try {
            scanner.startScan(null, settings, callback)
            true
        } catch (_: SecurityException) {
            false
        } catch (_: IllegalStateException) {
            false
        }
        scanFailedAt = if (isScanning) null else currentTime()
    }

    private val callback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            didDiscover(result)
        }

        override fun onBatchScanResults(results: MutableList<ScanResult>) {
            for (result in results) didDiscover(result)
        }

        override fun onScanFailed(errorCode: Int) {
            scope.launch {
                isScanning = false
                scanFailedAt = currentTime()
            }
        }
    }

    /**
     * Reads only what matching needs: the address (digested at once), an Eddystone UID if there is
     * one, RSSI, and the advertisement's class (digested; the manufacturer data itself is not kept).
     * The local name is never read.
     */
    private fun didDiscover(result: ScanResult) {
        if (!buffer.wantsScan) return
        val record = result.scanRecord
        val services = record?.serviceUuids.orEmpty().map { uuidString(it) }
        val serviceData = HashMap<String, ByteArray>()
        record?.serviceData?.forEach { (uuid, data) -> if (data != null) serviceData[uuidString(uuid)] = data }
        val manufacturer = record?.manufacturerSpecificData?.takeIf { it.size() > 0 }
            ?.let { manufacturerData(it.keyAt(0), it.valueAt(0) ?: ByteArray(0)) }
        val advertisementClass = AmbientEmitterKey.advertisementClass(manufacturer, services, result.isConnectable)
        buffer.add(
            AmbientAdvertisement(
                time = currentTime(),
                emitter = AmbientEmitterKey.best(result.device.address, serviceData),
                rssi = result.rssi.toDouble(),
                advertisementClass = advertisementClass,
                serviceUUIDs = services,
            )
        )
    }

    /** The rolling recorder, shared between the scan callback and the main thread. */
    private class Buffer(excludedServices: Set<String>) {
        private val lock = Any()
        private val recorder = AmbientRecorder(excludedServices, horizon)
        private var lastPrune = 0.0
        @Volatile var wantsScan = false

        fun add(advertisement: AmbientAdvertisement) = synchronized(lock) {
            if (!wantsScan) return@synchronized
            recorder.add(advertisement)
            if (advertisement.time - lastPrune > 10) {
                recorder.prune(advertisement.time)
                lastPrune = advertisement.time
            }
        }

        fun snapshot(start: TimeInterval, end: TimeInterval): AmbientSnapshot =
            synchronized(lock) { recorder.snapshot(start, end) }

        fun deviceCount(now: TimeInterval): Int = synchronized(lock) {
            recorder.prune(now)
            recorder.emitterCount
        }

        fun clear() = synchronized(lock) { recorder.removeAll() }
    }
}

/**
 * The recorded spots, kept on this phone only: a JSON file in the app's no-backup files folder
 * (Swift: file-protected, excluded from iCloud backup), never relayed or uploaded.
 */
class FingerprintStore(context: Context) {
    var database: FingerprintDatabase by mutableStateOf(FingerprintDatabase())
        private set
    private val file = File(context.applicationContext.noBackupFilesDir, "ambient-fingerprints.json")

    init {
        try {
            if (file.exists()) database = FingerprintDatabase.decode(file.readBytes())
        } catch (_: Exception) {
        }
    }

    fun add(fingerprint: RadioFingerprint) {
        // FingerprintDatabase is a Swift struct: change a copy and publish it.
        database = database.copy().also { it.add(fingerprint) }
        save()
    }

    fun remove(id: String) {
        database = database.copy().also { it.remove(id) }
        save()
    }

    fun removeAll() {
        database = FingerprintDatabase()
        save()
    }

    private fun save() {
        try {
            file.parentFile?.mkdirs()
            val temporary = File(file.parentFile, file.name + ".tmp")
            temporary.writeBytes(database.encoded())
            if (!temporary.renameTo(file)) {
                file.delete()
                temporary.renameTo(file)
            }
        } catch (_: Exception) {
            // The spots stay in memory for this session; nothing else depends on the file.
        }
    }
}
