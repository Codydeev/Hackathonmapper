package com.hackathonmapper.meshmapper

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.runtime.LaunchedEffect
import androidx.core.content.ContextCompat
import com.hackathonmapper.meshmapper.ui.MeshMapperTheme

/**
 * MeshMapperApp.swift: one window with the map, the model shared by every screen, the
 * `meshmapper://gateway?url=…&token=…` link from the dashboard's QR code, and the screen kept on
 * while the mesh runs. Android also needs runtime permissions before Bluetooth can scan,
 * advertise or connect; the mesh starts once they are granted.
 */
class MainActivity : ComponentActivity() {
    private val model: MeshModel by viewModels()

    /** Bluetooth needs these; without them the mesh cannot start. */
    private val requiredPermissions: Array<String>
        get() = BluetoothMesh.requiredPermissions

    /** Required plus GPS: without location the phone is placed from Bluetooth, like a denied iPhone. */
    private val requestedPermissions: Array<String>
        get() = (requiredPermissions + LocationSource.permissions).distinct().toTypedArray()

    /** Set after a denial without a rationale: the system dialog won't show again, so open settings. */
    private var deniedForGood = false

    private val permissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { _ ->
            // A refusal of location shows as "Location not allowed" (CLAuthorizationStatus.denied).
            model.location.refreshAuthorization(afterRequest = true)
            if (!hasRequiredPermissions()) {
                deniedForGood = requiredPermissions.none { shouldShowRequestPermissionRationale(it) }
            }
            checkPermissionsAndLaunch()
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        model.onRequestPermissions = { requestPermissions() }
        setContent {
            MeshMapperTheme {
                val keepOn = model.isIdleTimerDisabled
                LaunchedEffect(keepOn) {
                    if (keepOn) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                }
                ContentView(model)
            }
        }
        if (savedInstanceState == null) intent?.data?.let { handleLink(it) }
        if (hasRequiredPermissions()) {
            checkPermissionsAndLaunch()
        } else {
            permissionLauncher.launch(requestedPermissions)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        intent.data?.let { handleLink(it) }
    }

    override fun onResume() {
        super.onResume()
        // Coming back from the app's system settings with the permissions now granted.
        model.location.refreshAuthorization()
        if (model.permissionProblem != null && hasRequiredPermissions()) checkPermissionsAndLaunch()
        model.scenePhaseChanged(ScenePhase.active)
    }

    override fun onPause() {
        model.scenePhaseChanged(ScenePhase.inactive)
        super.onPause()
    }

    override fun onStop() {
        model.scenePhaseChanged(ScenePhase.background)
        super.onStop()
    }

    override fun onDestroy() {
        // The model outlives a rotated activity; the next onCreate sets its own callback.
        model.onRequestPermissions = null
        super.onDestroy()
    }

    private fun handleLink(uri: Uri) {
        if (uri.scheme.equals("meshmapper", ignoreCase = true)) model.applyConnectLink(uri)
    }

    private fun hasRequiredPermissions(): Boolean = requiredPermissions.all {
        ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED
    }

    private fun checkPermissionsAndLaunch() {
        if (hasRequiredPermissions()) {
            model.permissionProblem = null
            deniedForGood = false
            model.launch()
        } else {
            model.permissionProblem = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                "Nearby devices permission denied: the mesh can't use Bluetooth. Allow it to start."
            } else {
                "Location permission denied: Android needs it to scan for Bluetooth phones. Allow it to start."
            }
            // The mesh can't start, but a scanned gateway link still fills in its settings.
            model.applyPendingConnectLink()
        }
    }

    /** Asks again, or opens the app's settings when Android no longer shows the dialog. */
    private fun requestPermissions() {
        if (deniedForGood) {
            startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null)),
            )
        } else {
            permissionLauncher.launch(requestedPermissions)
        }
    }
}
