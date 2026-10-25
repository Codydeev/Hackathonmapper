package com.hackathonmapper.meshmapper

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import com.hackathonmapper.meshcore.DashboardContract
import com.hackathonmapper.meshcore.Frame
import com.hackathonmapper.meshcore.FrameAssembler
import com.hackathonmapper.meshcore.FrameType
import com.hackathonmapper.meshcore.Framing
import com.hackathonmapper.meshcore.Hello
import com.hackathonmapper.meshcore.LinkOutbox
import com.hackathonmapper.meshcore.MeshProtocol
import com.hackathonmapper.meshcore.NeighborObservation
import com.hackathonmapper.meshcore.RSSIStatistics
import com.hackathonmapper.meshcore.TimeInterval
import com.hackathonmapper.meshcore.currentTime
import com.hackathonmapper.meshcore.swiftRounded
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.util.UUID
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.random.Random

/**
 * A phone seen advertising the mesh service. Bluetooth addresses differ per observer and rotate,
 * so they are for debugging only; mesh identity comes from the link Hello. `id` is the BLE
 * address (Swift: the Core Bluetooth peripheral UUID).
 */
data class RadioPeer(
    val id: String,
    val name: String,
    /** Advertisement RSSI: advertising channels at an irregular rate. A snapshot; replaced, never mutated. */
    val rssi: RSSIStatistics = RSSIStatistics(),
    val lastSeen: Double = currentTime(),
)

/** A mesh device with at least one ready link, identified through the link Hello. */
data class MeshNeighbor(
    val deviceId: String,
    val label: String?,
    val outgoing: Boolean,
    val incoming: Boolean,
    /** Connection RSSI, sampled at 1 Hz; only available where this phone is the central. */
    val connectionRSSI: RSSIStatistics?,
    val advertisementRSSI: RSSIStatistics?,
    val lastHeard: Double?,
) {
    val id: String get() = deviceId
}

data class MeshIdentity(
    val deviceId: String,
    val label: String?,
    val frameId: String,
)

/** A BLE link: transport handle only (the remote BLE address), never a mesh identity. */
sealed class LinkID {
    abstract val address: String

    /** This phone is the central; the remote peripheral's address. */
    data class Outgoing(override val address: String) : LinkID()

    /** This phone is the peripheral; the remote central's address. */
    data class Incoming(override val address: String) : LinkID()

    val isOutgoing: Boolean get() = this is Outgoing
}

enum class LinkState {
    connecting, linking, ready,
}

/** Swift `CBManagerState`, for the central (scan/connect) and peripheral (advertise/serve) roles. */
enum class BluetoothState {
    unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn,
}

private class Link(
    var state: LinkState,
    val startedAt: Double,
    /** Central: notifications enabled. Peripheral: the central subscribed. */
    var subscribed: Boolean = false,
) {
    var readyAt: Double? = null
    /** Hello mismatch on an incoming link, which this phone leaves to the central to close (as on iOS). */
    var rejected = false
    var deviceId: String? = null
    var label: String? = null
    var lastHeard: Double? = null
    val outbox = LinkOutbox()
    val assembler = FrameAssembler()
    val connectionRSSI = RSSIStatistics()
}

/** One Android GATT operation; a connection runs one at a time. */
private sealed class GattOp {
    object RequestMtu : GattOp()
    object DiscoverServices : GattOp()
    object EnableNotifications : GattOp()
    class Write(val chunk: ByteArray) : GattOp()
    object ReadRssi : GattOp()
}

/** A client connection to a remote peripheral, with its GATT operation queue. */
private class GattConnection(val address: String, val gatt: BluetoothGatt) {
    var connected = false
    /** ATT MTU from `onMtuChanged`; 23 until negotiated. */
    var mtu = 23
    var characteristic: BluetoothGattCharacteristic? = null
    val ops = ArrayDeque<GattOp>()
    var current: GattOp? = null
    var currentSince = 0.0
}

/**
 * The BLE mesh transport, ported from `BluetoothMesh.swift`. Each phone is both a central (scans
 * for the mesh service, connects, writes) and a peripheral (advertises the service, receives
 * writes, notifies). All state is read and written on the main thread: Android delivers GATT,
 * scan and advertise callbacks on binder threads, and each one is posted to the main looper.
 */
class BluetoothMesh(context: Context) {
    companion object {
        val serviceID: UUID = UUID.fromString("F7A40001-5AB1-4E90-A989-21B5E52E2210")
        val characteristicID: UUID = UUID.fromString("F7A40002-5AB1-4E90-A989-21B5E52E2210")
        /** Client Characteristic Configuration descriptor: writing it subscribes to notifications. */
        val cccdID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        /** Logical neighbors per phone; an app resource budget, not an Android limit. */
        const val maxNeighbors = 8
        /** Connect, discovery, subscription and Hello must finish within this time. */
        const val linkTimeout: TimeInterval = 10.0
        const val rejectRetryDelay: TimeInterval = 60.0
        /** A link that stayed ready this long resets its peripheral's failure backoff. */
        const val stableLinkAge: TimeInterval = 30.0
        /** A GATT operation or notification without its callback this long is treated as lost. */
        const val operationTimeout: TimeInterval = 5.0
        /**
         * MTU we ask for: MTU − 3 = 512, the longest attribute value, so an iPhone (which sizes its
         * chunks as MTU − 3 without a 512 cap) never sends a longer one on links we start.
         */
        const val requestedMtu = 515
        /** After a failed scan start (e.g. Android's 5-starts-per-30-s limit), wait this long to retry. */
        const val scanRetryDelay: TimeInterval = 30.0
        /** Longest attribute value ATT allows; Android rejects longer writes and notifications. */
        const val maxAttributeLength = 512
        /** ATT error "Unlikely Error", what iOS answers with `.unlikelyError`. */
        private const val attUnlikelyError = 0x0E

        /** Runtime permissions the mesh needs; the Activity requests these before `start`. */
        val requiredPermissions: Array<String>
            get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                arrayOf(
                    Manifest.permission.BLUETOOTH_SCAN,
                    Manifest.permission.BLUETOOTH_ADVERTISE,
                    Manifest.permission.BLUETOOTH_CONNECT,
                )
            } else {
                // Before Android 12, scan results need location permission (and location turned on).
                arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
            }

        /** One ATT write or notification: MTU − 3, within the 512-byte attribute limit. */
        fun chunkLength(mtu: Int): Int = min(maxAttributeLength, max(20, mtu - 3))

        fun stateName(state: BluetoothState): String = when (state) {
            BluetoothState.poweredOn -> "on"
            BluetoothState.poweredOff -> "off"
            BluetoothState.unauthorized -> "permission denied"
            BluetoothState.unsupported -> "unsupported"
            BluetoothState.resetting -> "resetting"
            BluetoothState.unknown -> "initializing"
        }

        fun gattStatusText(status: Int): String = when (status) {
            8 -> "Bluetooth connection timed out"
            19 -> "The nearby phone closed the connection"
            22 -> "This phone closed the connection"
            62 -> "Bluetooth connection could not be established"
            133 -> "Bluetooth connection failed (GATT error 133)"
            147 -> "Bluetooth connection timed out (GATT error 147)"
            else -> "Bluetooth error $status"
        }
    }

    private sealed class Retry {
        object Backoff : Retry()
        class After(val delay: TimeInterval) : Retry()
    }

    var peers: Map<String, RadioPeer> by mutableStateOf(emptyMap())
        private set
    var neighbors: List<MeshNeighbor> by mutableStateOf(emptyList())
        private set
    var pendingLinks: Int by mutableStateOf(0)
        private set
    var status: String by mutableStateOf("Bluetooth stopped")
        private set
    var lastError: String? by mutableStateOf(null)
        private set
    /** Swift `central.state`: scanning and connecting. */
    var centralState: BluetoothState by mutableStateOf(BluetoothState.unknown)
        private set
    /** Swift `peripheralManager.state`: advertising and serving incoming links. */
    var peripheralState: BluetoothState by mutableStateOf(BluetoothState.unknown)
        private set
    /** Runtime permissions from [requiredPermissions] not granted yet. */
    var missingPermissions: List<String> by mutableStateOf(emptyList())
        private set

    /** Position packet payload plus the device ID of the neighbor it arrived from. */
    var onPacket: ((ByteArray, String) -> Unit)? = null
    /** A neighbor gained its first ready link. */
    var onNeighborReady: ((String) -> Unit)? = null
    /** Link-local ranging frame (`rangingToken` or `rangingFix`) plus the neighbor's device ID. */
    var onRanging: ((FrameType, ByteArray, String) -> Unit)? = null

    private val appContext = context.applicationContext
    private val manager = appContext.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager?
    private val adapter: BluetoothAdapter? = manager?.adapter
    private val hasLowEnergy = appContext.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)
    private val main = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    private var gattServer: BluetoothGattServer? = null
    private var characteristic: BluetoothGattCharacteristic? = null
    private var serviceAdded = false
    private var scanning = false
    private var scanFailedAt: Double? = null
    private var advertising = false
    private var advertisingStarting = false
    private var running = false
    private var identity: MeshIdentity? = null
    private val links = LinkedHashMap<LinkID, Link>()
    /** Swift `peripherals`: devices seen advertising, by address. */
    private val devices = HashMap<String, BluetoothDevice>()
    /** Client connections (Swift: connected `CBPeripheral`s and their characteristics). */
    private val connections = HashMap<String, GattConnection>()
    private val subscribers = HashMap<String, BluetoothDevice>()
    /** Addresses with a write queued or in flight. */
    private val writing = HashSet<String>()
    private val retryAfter = HashMap<String, Double>()
    private val failures = HashMap<String, Int>()
    /** Device ID learned from the Hello of each peripheral this phone connected to. */
    private val peripheralDevice = HashMap<String, String>()
    private val relayTokens = HashMap<String, Int>()
    /** Peripheral role: ATT MTU each central negotiated. */
    private val serverMtu = HashMap<String, Int>()
    /** Peripheral role: the link with a notification in flight per central, and since when. */
    private val notifying = HashMap<String, Pair<Link, Double>>()
    /** Peripheral role: CCCD value each central wrote. */
    private val cccdValues = HashMap<String, ByteArray>()
    /** Peripheral role: prepared (long) writes waiting for their execute request. */
    private val preparedWrites = HashMap<String, java.io.ByteArrayOutputStream>()
    /** Peripheral role: centrals connected to the GATT server. */
    private val serverConnections = HashMap<String, BluetoothDevice>()
    private var timer: Job? = null

    private val stateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == BluetoothAdapter.ACTION_STATE_CHANGED) onMain { adapterStateChanged() }
        }
    }

    init {
        ContextCompat.registerReceiver(
            appContext, stateReceiver, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        refreshState()
    }

    private fun onMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block() else main.post(block)
    }

    // MARK: Permissions and state

    private fun granted(permission: String): Boolean =
        ContextCompat.checkSelfPermission(appContext, permission) == PackageManager.PERMISSION_GRANTED

    private val canScan: Boolean
        get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) granted(Manifest.permission.BLUETOOTH_SCAN)
        else granted(Manifest.permission.ACCESS_FINE_LOCATION) ||
            (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q && granted(Manifest.permission.ACCESS_COARSE_LOCATION))

    private val canConnect: Boolean
        get() = Build.VERSION.SDK_INT < Build.VERSION_CODES.S || granted(Manifest.permission.BLUETOOTH_CONNECT)

    private val canAdvertise: Boolean
        get() = Build.VERSION.SDK_INT < Build.VERSION_CODES.S || granted(Manifest.permission.BLUETOOTH_ADVERTISE)

    /**
     * Runs a Bluetooth call. A revoked permission, or the adapter turning off underneath the call
     * (`IllegalStateException: BT Adapter is not turned ON`), becomes an error message, not a crash.
     */
    private inline fun <T> ble(fallback: T, block: () -> T): T = try {
        block()
    } catch (error: SecurityException) {
        lastError = "Bluetooth permission missing: ${error.message ?: "allow Nearby devices"}"
        fallback
    } catch (error: IllegalStateException) {
        lastError = "Bluetooth is not on: ${error.message ?: "turn Bluetooth on"}"
        fallback
    }

    @SuppressLint("MissingPermission") // getState needs no runtime permission; wrapped anyway.
    private fun adapterState(): BluetoothState {
        val adapter = adapter
        if (adapter == null || !hasLowEnergy) return BluetoothState.unsupported
        val state = try {
            adapter.state
        } catch (_: SecurityException) {
            return BluetoothState.unauthorized
        }
        return when (state) {
            BluetoothAdapter.STATE_ON -> BluetoothState.poweredOn
            BluetoothAdapter.STATE_OFF -> BluetoothState.poweredOff
            BluetoothAdapter.STATE_TURNING_ON, BluetoothAdapter.STATE_TURNING_OFF -> BluetoothState.resetting
            else -> BluetoothState.unknown
        }
    }

    /** Re-reads adapter power, BLE support and runtime permissions into the published states. */
    private fun refreshState() {
        val power = adapterState()
        val missing = requiredPermissions.filter { !granted(it) }
        if (missing != missingPermissions) missingPermissions = missing
        val central = when {
            power != BluetoothState.poweredOn -> power
            !canScan || !canConnect -> BluetoothState.unauthorized
            else -> BluetoothState.poweredOn
        }
        val peripheral = when {
            power != BluetoothState.poweredOn -> power
            adapter?.bluetoothLeAdvertiser == null || adapter.isMultipleAdvertisementSupported == false ->
                BluetoothState.unsupported
            !canAdvertise || !canConnect -> BluetoothState.unauthorized
            else -> BluetoothState.poweredOn
        }
        if (central != centralState) centralState = central
        if (peripheral != peripheralState) peripheralState = peripheral
    }

    /** Swift's `centralManagerDidUpdateState` and `peripheralManagerDidUpdateState` in one. */
    private fun adapterStateChanged() {
        refreshState()
        if (centralState != BluetoothState.poweredOn) {
            for (address in connections.keys.toList()) releaseGatt(address)
            links.keys.removeAll { it.isOutgoing }
            devices.clear()
            writing.clear()
            scanning = false
            refreshNeighbors()
        }
        if (peripheralState != BluetoothState.poweredOn) {
            closeServer(disconnect = false)
            links.keys.removeAll { !it.isOutgoing }
            refreshNeighbors()
        }
        activate()
    }

    // MARK: Start and stop

    fun start(identity: MeshIdentity) {
        this.identity = identity
        running = true
        activate()
        timer?.cancel()
        timer = scope.launch {
            while (isActive) {
                delay(1_000)
                tick()
            }
        }
    }

    /**
     * Rescans and re-advertises, for example after returning to the foreground. Also call it after
     * the Bluetooth permissions were granted: Android has no callback for that.
     */
    fun resume() {
        activate()
    }

    @SuppressLint("MissingPermission") // Every call checks its permission or is wrapped in ble { }.
    fun stop() {
        running = false
        timer?.cancel()
        timer = null
        stopScan()
        // Closing the server ends remote subscriptions, so no stale links survive a restart.
        closeServer(disconnect = true)
        for (address in connections.keys.toList()) releaseGatt(address)
        links.clear()
        devices.clear()
        writing.clear()
        retryAfter.clear()
        failures.clear()
        peripheralDevice.clear()
        relayTokens.clear()
        peers = emptyMap()
        refreshNeighbors()
        status = "Bluetooth stopped"
    }

    /** Unregisters the adapter-state receiver; the instance is unusable afterwards. */
    fun release() {
        stop()
        try {
            appContext.unregisterReceiver(stateReceiver)
        } catch (_: IllegalArgumentException) {
        }
    }

    @SuppressLint("MissingPermission")
    private fun activate() {
        if (!running) return
        refreshState()
        val centralOn = centralState == BluetoothState.poweredOn
        val peripheralOn = peripheralState == BluetoothState.poweredOn
        // A phone that cannot advertise at all still links out as a central (iOS always can do both).
        val centralOnly = centralOn && peripheralState == BluetoothState.unsupported
        if (!centralOn || (!peripheralOn && !centralOnly)) {
            status = "Bluetooth unavailable: ${stateName(centralState)} / ${stateName(peripheralState)}"
            return
        }
        startScan()
        if (centralOnly) {
            status = "Scanning only: this phone cannot advertise, so others cannot link to it"
            return
        }
        if (gattServer == null) {
            gattServer = ble(null) { manager?.openGattServer(appContext, serverCallback) }
            if (gattServer == null) {
                lastError = "Could not open the Bluetooth GATT server"
                status = "Scanning only (GATT server unavailable)"
                return
            }
            serviceAdded = false
            characteristic = null
        }
        if (serviceAdded) {
            if (!advertising) startAdvertising()
        } else if (characteristic == null) {
            val value = BluetoothGattCharacteristic(
                characteristicID,
                BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                BluetoothGattCharacteristic.PERMISSION_WRITE,
            )
            value.addDescriptor(
                BluetoothGattDescriptor(
                    cccdID,
                    BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE,
                )
            )
            val service = BluetoothGattService(serviceID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
            service.addCharacteristic(value)
            characteristic = value
            val added = ble(false) { gattServer?.addService(service) == true }
            if (!added) {
                characteristic = null
                lastError = "Could not add the mesh Bluetooth service"
            }
        }
        status = "Scanning and advertising (foreground)"
    }

    @SuppressLint("MissingPermission")
    private fun startScan() {
        if (scanning || !canScan) return
        val scanner = adapter?.bluetoothLeScanner ?: return
        val filters = listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(serviceID)).build())
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
            .setReportDelay(0)
            .build()
        scanning = ble(false) {
            scanner.startScan(filters, settings, scanCallback)
            true
        }
        if (!scanning) scanFailedAt = currentTime()
    }

    @SuppressLint("MissingPermission")
    private fun stopScan() {
        if (scanning && canScan) ble(Unit) { adapter?.bluetoothLeScanner?.stopScan(scanCallback) }
        scanning = false
    }

    @SuppressLint("MissingPermission")
    private fun startAdvertising() {
        if (advertising || advertisingStarting || !canAdvertise) return
        val advertiser = adapter?.bluetoothLeAdvertiser ?: return
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(true)
            .setTimeout(0)
            .build()
        // Only the 128-bit service UUID: with flags it fits the 31-byte legacy advertisement.
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .addServiceUuid(ParcelUuid(serviceID))
            .build()
        advertisingStarting = ble(false) {
            advertiser.startAdvertising(settings, data, advertiseCallback)
            true
        }
    }

    @SuppressLint("MissingPermission")
    private fun closeServer(disconnect: Boolean) {
        if (advertising || advertisingStarting) {
            if (canAdvertise) ble(Unit) { adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback) }
        }
        advertising = false
        advertisingStarting = false
        gattServer?.let { server ->
            ble(Unit) {
                if (disconnect && canConnect) {
                    for (device in serverConnections.values) server.cancelConnection(device)
                }
                server.clearServices()
                server.close()
            }
        }
        gattServer = null
        characteristic = null
        serviceAdded = false
        subscribers.clear()
        serverConnections.clear()
        serverMtu.clear()
        notifying.clear()
        cccdValues.clear()
        preparedWrites.clear()
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            onMain {
                advertisingStarting = false
                advertising = true
            }
        }

        override fun onStartFailure(errorCode: Int) {
            onMain {
                advertisingStarting = false
                if (errorCode == ADVERTISE_FAILED_ALREADY_STARTED) {
                    advertising = true
                } else {
                    advertising = false
                    lastError = when (errorCode) {
                        ADVERTISE_FAILED_DATA_TOO_LARGE -> "Bluetooth advertisement too large"
                        ADVERTISE_FAILED_TOO_MANY_ADVERTISERS -> "Too many Bluetooth advertisers on this phone"
                        ADVERTISE_FAILED_FEATURE_UNSUPPORTED -> "This phone cannot advertise over Bluetooth LE"
                        else -> "Bluetooth advertising failed (error $errorCode)"
                    }
                }
            }
        }
    }

    // MARK: Central role (outgoing links)

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val device = result.device
            val rssi = result.rssi
            val name = result.scanRecord?.deviceName
            onMain { didDiscover(device, rssi, name) }
        }

        override fun onBatchScanResults(results: MutableList<ScanResult>) {
            val found = results.map { Triple(it.device, it.rssi, it.scanRecord?.deviceName) }
            onMain { for ((device, rssi, name) in found) didDiscover(device, rssi, name) }
        }

        override fun onScanFailed(errorCode: Int) {
            onMain {
                scanning = false
                scanFailedAt = currentTime()
                lastError = "Bluetooth scan failed (error $errorCode)"
            }
        }
    }

    @SuppressLint("MissingPermission")
    private fun didDiscover(device: BluetoothDevice, rssi: Int, name: String?) {
        if (!running) return
        val id = device.address
        val now = currentTime()
        if (peers[id] == null && peers.size >= 100) return
        val previous = peers[id]
        val stats = previous?.rssi?.copy() ?: RSSIStatistics()
        stats.record(rssi, now)
        peers = peers + (id to RadioPeer(id, previous?.name ?: name ?: "Mapping phone", stats, now))
        devices[id] = device

        if (connections[id] != null || links[LinkID.Outgoing(id)] != null || now < (retryAfter[id] ?: 0.0)) return
        // Already linked to this device in the other direction.
        val deviceId = peripheralDevice[id]
        if (deviceId != null && hasReadyLink(deviceId)) return
        if (links.keys.count { it.isOutgoing } >= maxNeighbors || readyNeighborIds.size >= maxNeighbors) return
        if (!canConnect) return
        links[LinkID.Outgoing(id)] = Link(LinkState.connecting, now)
        val gatt = ble(null) {
            device.connectGatt(appContext, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
        }
        if (gatt == null) {
            closeOutgoing(id, Retry.Backoff, "Could not connect to a nearby phone")
            return
        }
        connections[id] = GattConnection(id, gatt)
        refreshNeighbors()
    }

    /** The connection a callback belongs to, or null for a stale (closed) `BluetoothGatt`. */
    private fun connection(gatt: BluetoothGatt): GattConnection? =
        connections[gatt.device.address]?.takeIf { it.gatt === gatt }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            onMain { connectionStateChanged(gatt, status, newState) }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            onMain {
                val connection = connection(gatt) ?: return@onMain
                if (status == BluetoothGatt.GATT_SUCCESS) connection.mtu = mtu
                // The peer may start an MTU exchange too; only ours completes the queued op.
                finishOp(connection, GattOp.RequestMtu)
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            onMain { servicesDiscovered(gatt, status) }
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            onMain { notificationStateChanged(gatt, status) }
        }

        override fun onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            onMain { didWrite(gatt, status) }
        }

        override fun onReadRemoteRssi(gatt: BluetoothGatt, rssi: Int, status: Int) {
            onMain {
                val connection = connection(gatt) ?: return@onMain
                val id = connection.address
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    links[LinkID.Outgoing(id)]?.connectionRSSI?.record(rssi)
                    peers[id]?.let { peers = peers + (id to it.copy(lastSeen = currentTime())) }
                }
                finishOp(connection, GattOp.ReadRssi)
            }
        }

        // Android 13+: the value arrives as its own array.
        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            if (characteristic.uuid != characteristicID) return
            val data = value.copyOf()
            onMain { didUpdateValue(gatt, data) }
        }

        // Android 8–12: the value is read from the shared characteristic, so copy it right here.
        @Deprecated("Deprecated in Java")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) return
            if (characteristic.uuid != characteristicID) return
            @Suppress("DEPRECATION")
            val data = characteristic.value?.copyOf() ?: return
            onMain { didUpdateValue(gatt, data) }
        }
    }

    @SuppressLint("MissingPermission")
    private fun connectionStateChanged(gatt: BluetoothGatt, status: Int, newState: Int) {
        val connection = connection(gatt)
        if (connection == null) {
            // A connection this phone already gave up on.
            if (newState == BluetoothProfile.STATE_DISCONNECTED) ble(Unit) { gatt.close() }
            return
        }
        val id = connection.address
        if (status == BluetoothGatt.GATT_SUCCESS && newState == BluetoothProfile.STATE_CONNECTED) {
            connection.connected = true
            if (!running || links[LinkID.Outgoing(id)] == null) {
                releaseGatt(id)
                return
            }
            links[LinkID.Outgoing(id)]?.state = LinkState.linking
            // Larger chunks first, then discovery; one GATT operation at a time.
            enqueueOp(connection, GattOp.RequestMtu)
            enqueueOp(connection, GattOp.DiscoverServices)
        } else if (newState == BluetoothProfile.STATE_DISCONNECTED || status != BluetoothGatt.GATT_SUCCESS) {
            // Includes status 133 (connection failed) and supervision timeouts: always close the gatt.
            releaseGatt(id)
            closeOutgoing(id, Retry.Backoff, if (status == BluetoothGatt.GATT_SUCCESS) null else gattStatusText(status))
        }
    }

    @SuppressLint("MissingPermission")
    private fun servicesDiscovered(gatt: BluetoothGatt, status: Int) {
        val connection = connection(gatt) ?: return
        val id = connection.address
        finishOp(connection, GattOp.DiscoverServices, runNext = false)
        if (status != BluetoothGatt.GATT_SUCCESS) {
            closeOutgoing(id, Retry.Backoff, "Service discovery failed: ${gattStatusText(status)}")
            return
        }
        val service = ble(null) { gatt.getService(serviceID) }
        if (service == null) {
            closeOutgoing(id, Retry.After(rejectRetryDelay), "Nearby device has no mesh service")
            return
        }
        val value = service.getCharacteristic(characteristicID)
        val properties = value?.properties ?: 0
        if (value == null || properties and BluetoothGattCharacteristic.PROPERTY_WRITE == 0 ||
            properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY == 0 || value.getDescriptor(cccdID) == null
        ) {
            closeOutgoing(id, Retry.After(rejectRetryDelay), "Nearby device has an incompatible mesh service")
            return
        }
        connection.characteristic = value
        if (!ble(false) { gatt.setCharacteristicNotification(value, true) }) {
            closeOutgoing(id, Retry.Backoff, "Could not enable Bluetooth notifications")
            return
        }
        enqueueOp(connection, GattOp.EnableNotifications)
    }

    /** Swift `didUpdateNotificationStateFor`: the CCCD write finished. */
    private fun notificationStateChanged(gatt: BluetoothGatt, status: Int) {
        val connection = connection(gatt) ?: return
        val id = connection.address
        finishOp(connection, GattOp.EnableNotifications, runNext = false)
        if (status != BluetoothGatt.GATT_SUCCESS) {
            closeOutgoing(id, Retry.Backoff, "Nearby phone refused notifications: ${gattStatusText(status)}")
            return
        }
        val link = links[LinkID.Outgoing(id)]
        if (link == null) {
            runNextOp(connection)
            return
        }
        link.subscribed = true
        sendHello(LinkID.Outgoing(id))
        updateReadiness(LinkID.Outgoing(id))
        connections[id]?.let { runNextOp(it) }
    }

    private fun didUpdateValue(gatt: BluetoothGatt, data: ByteArray) {
        if (!running || connection(gatt) == null) return
        receive(data, LinkID.Outgoing(gatt.device.address))
    }

    private fun didWrite(gatt: BluetoothGatt, status: Int) {
        val connection = connection(gatt) ?: return
        val id = connection.address
        finishOp(connection, null, runNext = false)
        writing.remove(id)
        if (status != BluetoothGatt.GATT_SUCCESS) {
            closeOutgoing(id, Retry.Backoff, "Bluetooth write failed: ${gattStatusText(status)}")
            return
        }
        links[LinkID.Outgoing(id)]?.outbox?.chunkSent()
        pumpWrite(id)
        connections[id]?.let { runNextOp(it) }
    }

    // GATT operation queue: Android allows one outstanding operation per connection.

    private fun enqueueOp(connection: GattConnection, op: GattOp) {
        connection.ops.addLast(op)
        runNextOp(connection)
    }

    /** Completes the running operation if it is of `kind` (any write when null). */
    private fun finishOp(connection: GattConnection, kind: GattOp?, runNext: Boolean = true) {
        val current = connection.current ?: return
        val matches = if (kind == null) current is GattOp.Write else current === kind
        if (!matches) return
        connection.current = null
        if (runNext) runNextOp(connection)
    }

    @SuppressLint("MissingPermission")
    private fun runNextOp(connection: GattConnection) {
        while (connection.current == null && connections[connection.address] === connection) {
            val op = connection.ops.removeFirstOrNull() ?: return
            val started = ble(false) { startOp(connection, op) }
            if (started) {
                connection.current = op
                connection.currentSince = currentTime()
                return
            }
            when (op) {
                // Optional: keep the 23-byte MTU, or skip this RSSI sample.
                GattOp.RequestMtu, GattOp.ReadRssi -> continue
                else -> {
                    if (op is GattOp.Write) writing.remove(connection.address)
                    closeOutgoing(connection.address, Retry.Backoff, "Bluetooth operation failed to start")
                    return
                }
            }
        }
    }

    @SuppressLint("MissingPermission") // Called through ble { } after canConnect was checked at connect.
    private fun startOp(connection: GattConnection, op: GattOp): Boolean {
        if (!canConnect) return false
        val gatt = connection.gatt
        return when (op) {
            GattOp.RequestMtu -> gatt.requestMtu(requestedMtu)
            GattOp.DiscoverServices -> gatt.discoverServices()
            GattOp.ReadRssi -> gatt.readRemoteRssi()
            GattOp.EnableNotifications -> {
                val descriptor = connection.characteristic?.getDescriptor(cccdID) ?: return false
                val enable = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    gatt.writeDescriptor(descriptor, enable) == BluetoothStatusCodes.SUCCESS
                } else {
                    @Suppress("DEPRECATION")
                    descriptor.value = enable
                    @Suppress("DEPRECATION")
                    gatt.writeDescriptor(descriptor)
                }
            }
            is GattOp.Write -> {
                val value = connection.characteristic ?: return false
                // With response, like iOS `.withResponse`; one chunk fits one ATT write.
                val type = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    gatt.writeCharacteristic(value, op.chunk, type) == BluetoothStatusCodes.SUCCESS
                } else {
                    value.writeType = type
                    @Suppress("DEPRECATION")
                    value.value = op.chunk
                    @Suppress("DEPRECATION")
                    gatt.writeCharacteristic(value)
                }
            }
        }
    }

    /** Disconnects and closes a client connection. A closed `BluetoothGatt` reports nothing more. */
    @SuppressLint("MissingPermission")
    private fun releaseGatt(address: String) {
        val connection = connections.remove(address) ?: return
        writing.remove(address)
        ble(Unit) {
            if (canConnect) connection.gatt.disconnect()
            connection.gatt.close()
        }
    }

    /** Ends an outgoing link and schedules the next attempt. Safe to call more than once. */
    private fun closeOutgoing(id: String, retry: Retry, reason: String? = null) {
        val link = links.remove(LinkID.Outgoing(id)) ?: return
        if (reason != null) lastError = reason
        writing.remove(id)
        releaseGatt(id)
        val now = currentTime()
        when (retry) {
            is Retry.After -> retryAfter[id] = now + retry.delay
            Retry.Backoff -> {
                val readyAt = link.readyAt
                if (readyAt != null && now - readyAt >= stableLinkAge) failures.remove(id)
                val count = (failures[id] ?: 0) + 1
                failures[id] = count
                // 5, 10, 20, 40, then 60 s, plus jitter so neighbors don't retry in lockstep.
                val delay = min(60.0, 5 * 2.0.pow(count - 1)) + Random.nextDouble(0.0, 2.0)
                retryAfter[id] = now + delay
            }
        }
        refreshNeighbors()
    }

    // MARK: Peripheral role (incoming links)

    private val serverCallback = object : BluetoothGattServerCallback() {
        override fun onServiceAdded(status: Int, service: BluetoothGattService) {
            onMain {
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    lastError = "Could not add the mesh Bluetooth service (status $status)"
                    characteristic = null
                    return@onMain
                }
                serviceAdded = true
                activate()
            }
        }

        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            onMain {
                // Also fires for connections this phone opened as a central; those only ever
                // matter here once they subscribe, which they never do.
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    serverConnections[device.address] = device
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    serverConnections.remove(device.address)
                    serverMtu.remove(device.address)
                    cccdValues.remove(device.address)
                    didUnsubscribe(device.address)
                }
            }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            onMain { serverMtu[device.address] = mtu }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice, requestId: Int, descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray?,
        ) {
            val data = value?.copyOf()
            val isCccd = descriptor.uuid == cccdID
            onMain { descriptorWrite(device, requestId, isCccd, preparedWrite, responseNeeded, offset, data) }
        }

        override fun onDescriptorReadRequest(
            device: BluetoothDevice, requestId: Int, offset: Int, descriptor: BluetoothGattDescriptor,
        ) {
            onMain {
                val value = cccdValues[device.address] ?: BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
                if (descriptor.uuid == cccdID && offset <= value.size) {
                    respond(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value.copyOfRange(offset, value.size))
                } else {
                    respond(device, requestId, BluetoothGatt.GATT_READ_NOT_PERMITTED, offset, null)
                }
            }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice, requestId: Int, characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray?,
        ) {
            val data = value?.copyOf()
            val matches = characteristic.uuid == characteristicID
            onMain { didReceiveWrite(device, requestId, matches, preparedWrite, responseNeeded, offset, data) }
        }

        override fun onExecuteWrite(device: BluetoothDevice, requestId: Int, execute: Boolean) {
            onMain { executeWrite(device, requestId, execute) }
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            onMain { notificationSent(device.address, status) }
        }
    }

    @SuppressLint("MissingPermission")
    private fun respond(device: BluetoothDevice, requestId: Int, status: Int, offset: Int, value: ByteArray?) {
        val server = gattServer ?: return
        if (!canConnect) return
        ble(Unit) { server.sendResponse(device, requestId, status, offset, value) }
    }

    private fun descriptorWrite(
        device: BluetoothDevice, requestId: Int, isCccd: Boolean, preparedWrite: Boolean,
        responseNeeded: Boolean, offset: Int, value: ByteArray?,
    ) {
        if (!isCccd || preparedWrite || offset != 0 || value == null || value.size != 2) {
            if (responseNeeded) respond(device, requestId, BluetoothGatt.GATT_WRITE_NOT_PERMITTED, offset, null)
            return
        }
        // Answer first, so the central sees the subscription succeed before our Hello arrives.
        if (responseNeeded) respond(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, value)
        cccdValues[device.address] = value
        val enabled = (value[0].toInt() and 0x03) != 0
        if (enabled) didSubscribe(device) else didUnsubscribe(device.address)
    }

    /** Swift `didSubscribeTo`: a central enabled notifications, which opens an incoming link. */
    private fun didSubscribe(device: BluetoothDevice) {
        if (!running) return
        val id = device.address
        val incoming = links.keys.count { !it.isOutgoing }
        if (links[LinkID.Incoming(id)] == null && incoming >= maxNeighbors) return
        subscribers[id] = device
        notifying.remove(id)
        preparedWrites.remove(id)
        links[LinkID.Incoming(id)] = Link(LinkState.linking, currentTime(), subscribed = true)
        sendHello(LinkID.Incoming(id))
        refreshNeighbors()
    }

    /** Swift `didUnsubscribeFrom`; also a central disconnecting. */
    private fun didUnsubscribe(id: String) {
        subscribers.remove(id)
        notifying.remove(id)
        preparedWrites.remove(id)
        if (links.remove(LinkID.Incoming(id)) != null) refreshNeighbors()
    }

    private fun isOpen(id: String): Boolean = links[LinkID.Incoming(id)]?.let { !it.rejected } ?: false

    /**
     * Swift `didReceiveWrite`. A failed write makes the central close the link and back off.
     * Without it, a central rejected for the neighbor limit already holds our valid Hello, treats
     * the link as ready and keeps sending packets that are dropped here.
     */
    private fun didReceiveWrite(
        device: BluetoothDevice, requestId: Int, matches: Boolean, preparedWrite: Boolean,
        responseNeeded: Boolean, offset: Int, value: ByteArray?,
    ) {
        val id = device.address
        if (preparedWrite) {
            // A long write: buffer it (bounded, in order) until the execute request.
            val buffer = preparedWrites.getOrPut(id) { java.io.ByteArrayOutputStream() }
            val valid = running && matches && value != null && isOpen(id) && offset == buffer.size() &&
                buffer.size() + value.size <= FrameAssembler.maxBuffered
            if (!valid) {
                preparedWrites.remove(id)
                if (responseNeeded) respond(device, requestId, attUnlikelyError, offset, null)
                return
            }
            buffer.write(value!!)
            if (responseNeeded) respond(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
            return
        }
        val valid = running && matches && offset == 0 && value != null && isOpen(id)
        if (!valid) {
            if (responseNeeded) respond(device, requestId, attUnlikelyError, offset, null)
            return
        }
        receive(value!!, LinkID.Incoming(id))
        if (responseNeeded) {
            respond(device, requestId, if (isOpen(id)) BluetoothGatt.GATT_SUCCESS else attUnlikelyError, offset, null)
        }
    }

    private fun executeWrite(device: BluetoothDevice, requestId: Int, execute: Boolean) {
        val id = device.address
        val buffer = preparedWrites.remove(id)
        if (!execute || buffer == null || buffer.size() == 0) {
            respond(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            return
        }
        if (!running || !isOpen(id)) {
            respond(device, requestId, attUnlikelyError, 0, null)
            return
        }
        receive(buffer.toByteArray(), LinkID.Incoming(id))
        respond(device, requestId, if (isOpen(id)) BluetoothGatt.GATT_SUCCESS else attUnlikelyError, 0, null)
    }

    /** Swift `peripheralManagerIsReady`: the notification went out; send the next chunk. */
    private fun notificationSent(id: String, status: Int) {
        val (link, _) = notifying.remove(id) ?: return
        // Only advance the link the chunk belonged to; a resubscribed central has a new one.
        if (status == BluetoothGatt.GATT_SUCCESS && links[LinkID.Incoming(id)] === link) {
            link.outbox.chunkSent()
            pumpNotifications()
        }
        // On failure the same chunk is retried by the next tick.
    }

    // MARK: Handshake

    private fun sendHello(linkId: LinkID) {
        val identity = identity ?: return
        val payload = try {
            Hello(frameId = identity.frameId, deviceId = identity.deviceId, label = identity.label).encoded()
        } catch (_: Exception) {
            return
        }
        val framed = Framing.encode(payload, FrameType.hello) ?: return
        enqueue(framed, "hello", linkId)
    }

    private fun handleHello(payload: ByteArray, linkId: LinkID) {
        val identity = identity ?: return
        if (links[linkId] == null) return
        val hello = try {
            Hello.decode(payload)
        } catch (_: Exception) {
            reject(linkId, "Invalid hello from a nearby phone")
            return
        }
        if (hello.protocolVersion != MeshProtocol.version) {
            reject(linkId, "A nearby phone runs mesh protocol ${hello.protocolVersion}; this phone runs ${MeshProtocol.version}. Update all phones.")
            return
        }
        if (hello.frameId != identity.frameId) {
            reject(linkId, "A nearby phone uses frame ${hello.frameId}")
            return
        }
        if (hello.deviceId == identity.deviceId) {
            reject(linkId, "Linked to itself")
            return
        }
        links[linkId]?.deviceId = hello.deviceId
        links[linkId]?.label = hello.label
        if (linkId is LinkID.Outgoing) peripheralDevice[linkId.address] = hello.deviceId
        updateReadiness(linkId)
    }

    private fun reject(linkId: LinkID, reason: String) {
        when (linkId) {
            is LinkID.Outgoing -> closeOutgoing(linkId.address, Retry.After(rejectRetryDelay), reason)
            is LinkID.Incoming -> {
                // Like iOS, leave closing to the central: it receives our Hello and disconnects.
                links[linkId]?.rejected = true
                lastError = reason
            }
        }
    }

    /** A link is ready once subscribed and a valid Hello arrived from the other side. */
    private fun updateReadiness(linkId: LinkID) {
        val link = links[linkId] ?: return
        if (link.state == LinkState.ready || link.rejected || !link.subscribed) return
        val deviceId = link.deviceId ?: return
        val isNewNeighbor = !hasReadyLink(deviceId)
        if (isNewNeighbor && readyNeighborIds.size >= maxNeighbors) {
            reject(linkId, "Neighbor limit ($maxNeighbors) reached")
            return
        }
        link.state = LinkState.ready
        link.readyAt = currentTime()
        reconcileLinks(deviceId)
        refreshNeighbors()
        if (isNewNeighbor) onNeighborReady?.invoke(deviceId)
    }

    /**
     * Keeps the link initiated by the lower device ID (app.md). Only the higher side holds a
     * redundant outgoing link it closes; incoming links are left to their central, as on iOS.
     */
    private fun reconcileLinks(deviceId: String) {
        val identity = identity ?: return
        if (identity.deviceId <= deviceId) return
        val ready = links.filter { it.value.deviceId == deviceId && it.value.state == LinkState.ready }.keys.toList()
        if (ready.none { !it.isOutgoing }) return
        for (linkId in ready) {
            if (linkId is LinkID.Outgoing) closeOutgoing(linkId.address, Retry.After(5.0))
        }
    }

    private fun hasReadyLink(deviceId: String): Boolean =
        links.values.any { it.deviceId == deviceId && it.state == LinkState.ready }

    private val readyNeighborIds: Set<String>
        get() = links.values.mapNotNullTo(HashSet()) { if (it.state == LinkState.ready) it.deviceId else null }

    private fun preferredLink(deviceId: String): LinkID? {
        val identity = identity ?: return null
        val ready = links.filter { it.value.deviceId == deviceId && it.value.state == LinkState.ready }.keys
        val canonicalIsOutgoing = identity.deviceId < deviceId
        return ready.firstOrNull { it.isOutgoing == canonicalIsOutgoing } ?: ready.firstOrNull()
    }

    // MARK: Sending

    /**
     * Queues a position packet once per ready neighbor, except `except`. A newer packet with the
     * same `key` replaces one still queued on a link.
     */
    fun broadcast(payload: ByteArray, key: String, except: String? = null) {
        if (!running) return
        val framed = Framing.encode(payload, FrameType.position) ?: return
        for (deviceId in readyNeighborIds) {
            if (deviceId == except) continue
            preferredLink(deviceId)?.let { enqueue(framed, key, it) }
        }
    }

    fun send(payload: ByteArray, type: FrameType = FrameType.position, key: String, to: String) {
        if (!running) return
        val framed = Framing.encode(payload, type) ?: return
        val linkId = preferredLink(to) ?: return
        enqueue(framed, key, linkId)
    }

    /**
     * Broadcasts after a random 0–100 ms delay so neighbors that received the same packet don't
     * all transmit at once. A later relay with the same key supersedes a pending one.
     */
    fun relay(payload: ByteArray, key: String, except: String) {
        val token = (relayTokens[key] ?: 0) + 1
        relayTokens[key] = token
        main.postDelayed({
            if (relayTokens[key] == token) broadcast(payload, key, except)
        }, Random.nextLong(0, 101))
    }

    private fun enqueue(framed: ByteArray, key: String, linkId: LinkID) {
        links[linkId]?.outbox?.enqueue(framed, key)
        when (linkId) {
            is LinkID.Outgoing -> pumpWrite(linkId.address)
            is LinkID.Incoming -> pumpNotifications()
        }
    }

    private fun pumpWrite(id: String) {
        if (!running || id in writing) return
        val connection = connections[id] ?: return
        if (!connection.connected || connection.characteristic == null) return
        // Fit a single ATT write: a longer one becomes a prepared write, which iOS rejects.
        val chunk = links[LinkID.Outgoing(id)]?.outbox?.nextChunk(chunkLength(connection.mtu)) ?: return
        writing.add(id)
        enqueueOp(connection, GattOp.Write(chunk))
    }

    @SuppressLint("MissingPermission")
    private fun pumpNotifications() {
        if (!running || !canConnect) return
        val server = gattServer ?: return
        val characteristic = characteristic ?: return
        for ((linkId, link) in links.entries.toList()) {
            if (linkId !is LinkID.Incoming || link.outbox.isEmpty) continue
            val id = linkId.address
            val subscriber = subscribers[id] ?: continue
            // One notification in flight per central; the next goes out from onNotificationSent.
            if (id in notifying) continue
            // The MTU belongs to the connection: if our client side already negotiated it with this
            // phone, the server-side onMtuChanged may never fire.
            val mtu = max(serverMtu[id] ?: 23, connections[id]?.mtu ?: 23)
            val chunk = link.outbox.nextChunk(chunkLength(mtu)) ?: continue
            val sent = ble(false) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    server.notifyCharacteristicChanged(subscriber, characteristic, false, chunk) ==
                        BluetoothStatusCodes.SUCCESS
                } else {
                    @Suppress("DEPRECATION")
                    characteristic.value = chunk
                    @Suppress("DEPRECATION")
                    server.notifyCharacteristicChanged(subscriber, characteristic, false)
                }
            }
            // Not sent (stack busy): the same chunk is retried by the next enqueue or tick.
            if (sent) notifying[id] = link to currentTime()
        }
    }

    // MARK: Receiving

    private fun receive(data: ByteArray, linkId: LinkID) {
        if (!running) return
        val link = links[linkId] ?: return
        val frames: List<Frame> = try {
            link.assembler.append(data)
        } catch (_: Exception) {
            link.assembler.reset()
            if (linkId is LinkID.Outgoing) {
                closeOutgoing(linkId.address, Retry.Backoff, "Invalid BLE frame; is every phone on the same app version?")
            } else {
                lastError = "Invalid BLE frame; is every phone on the same app version?"
            }
            return
        }
        link.lastHeard = currentTime()
        for (frame in frames) {
            when (frame.type) {
                FrameType.hello -> handleHello(frame.payload, linkId)
                FrameType.position, FrameType.rangingToken, FrameType.rangingFix -> {
                    val current = links[linkId] ?: continue
                    if (current.state != LinkState.ready) continue
                    val deviceId = current.deviceId ?: continue
                    if (frame.type == FrameType.position) {
                        onPacket?.invoke(frame.payload, deviceId)
                    } else {
                        onRanging?.invoke(frame.type, frame.payload, deviceId)
                    }
                }
            }
        }
    }

    // MARK: Neighbors

    /**
     * Ready links for `DeviceUpdate.neighbors`: connection RSSI where this phone is the central,
     * otherwise the neighbor's advertisement RSSI. Link quality only, never a distance.
     */
    fun neighborObservations(now: Double = currentTime()): List<NeighborObservation> {
        refreshNeighbors()
        return neighbors.take(DashboardContract.maxNeighbors).map { neighbor ->
            val rssi = (neighbor.connectionRSSI ?: neighbor.advertisementRSSI)?.smoothed?.let { swiftRounded(it).toInt() }
            val age = neighbor.lastHeard?.let {
                val millis = swiftRounded((now - it) * 1000)
                if (millis.isFinite()) millis.coerceIn(0.0, DashboardContract.maxAgeMs.toDouble()).toInt() else null
            }
            NeighborObservation(id = neighbor.deviceId, rssi = rssi, ageMs = age)
        }
    }

    private fun refreshNeighbors() {
        neighbors = readyNeighborIds.sorted().map { deviceId ->
            val ready = links.filter { it.value.deviceId == deviceId && it.value.state == LinkState.ready }
            val outgoing = ready.entries.firstOrNull { it.key.isOutgoing }?.value
            val advertisement = peripheralDevice.entries.firstOrNull { it.value == deviceId }?.let { peers[it.key]?.rssi }
            MeshNeighbor(
                deviceId = deviceId,
                label = ready.values.firstNotNullOfOrNull { it.label },
                outgoing = outgoing != null,
                incoming = ready.keys.any { !it.isOutgoing },
                // Snapshots: the link keeps sampling into its own statistics.
                connectionRSSI = outgoing?.connectionRSSI?.takeIf { it.sampleCount > 0 }?.copy(),
                advertisementRSSI = advertisement?.copy(),
                lastHeard = ready.values.mapNotNull { it.lastHeard }.maxOrNull(),
            )
        }
        val pending = links.values.count { it.state != LinkState.ready }
        if (pending != pendingLinks) pendingLinks = pending
    }

    private fun tick() {
        if (!running) return
        val now = currentTime()
        for ((linkId, link) in links.entries.toList()) {
            links[linkId]?.assembler?.expire(now)
            if (linkId !is LinkID.Outgoing) continue
            val id = linkId.address
            if (link.state != LinkState.ready && now - link.startedAt > linkTimeout) {
                closeOutgoing(id, Retry.Backoff, "Link setup timed out")
                continue
            }
            val readyAt = link.readyAt
            if (readyAt != null && now - readyAt >= stableLinkAge) failures.remove(id)
            val connection = connections[id] ?: continue
            val current = connection.current
            if (current != null && now - connection.currentSince > operationTimeout) {
                // A lost MTU or RSSI callback is harmless, as on iOS: skip it rather than drop the link.
                if (current === GattOp.RequestMtu || current === GattOp.ReadRssi) {
                    finishOp(connection, current)
                } else {
                    closeOutgoing(id, Retry.Backoff, "Bluetooth operation timed out")
                    continue
                }
            }
            if (connection.connected && connection.current !== GattOp.ReadRssi && GattOp.ReadRssi !in connection.ops) {
                enqueueOp(connection, GattOp.ReadRssi)
            }
        }
        // A notification whose callback never came is taken as sent, so the link moves on; if it
        // was lost, the central's frame check closes and rebuilds the link.
        for ((id, entry) in notifying.entries.toList()) {
            if (now - entry.second > operationTimeout) notificationSent(id, BluetoothGatt.GATT_SUCCESS)
        }
        // Restart a scan that failed to start; activate() is the only other place that starts one.
        val failedAt = scanFailedAt
        if (!scanning && failedAt != null && now - failedAt >= scanRetryDelay && centralState == BluetoothState.poweredOn) {
            scanFailedAt = null
            startScan()
        }
        val expired = peers.filter { (id, peer) -> now - peer.lastSeen > 30 && links[LinkID.Outgoing(id)] == null }.keys
        if (expired.isNotEmpty()) {
            for (id in expired) {
                releaseGatt(id)
                devices.remove(id)
                retryAfter.remove(id)
                failures.remove(id)
                peripheralDevice.remove(id)
            }
            peers = peers - expired
        }
        pumpNotifications()
        refreshNeighbors()
    }
}
