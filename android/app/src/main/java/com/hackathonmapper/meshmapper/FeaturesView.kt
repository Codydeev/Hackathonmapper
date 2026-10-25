package com.hackathonmapper.meshmapper

import androidx.compose.runtime.Composable
import com.hackathonmapper.meshcore.FeatureFlags
import com.hackathonmapper.meshcore.PeerPlacement
import com.hackathonmapper.meshcore.PredictionMode
import com.hackathonmapper.meshcore.SignalRanges

/**
 * Every feature switch in one place, so combinations can be tried on the phones without a new build.
 * Each takes effect at once and is remembered (`MeshModel.features`), except the GPS check, which
 * applies when the mesh starts.
 *
 * Its navigation title ("Features") is set by the link that opens it (`NavigationLinkRow`).
 */
@Composable
fun FeaturesView(model: MeshModel) {
    val features = model.features
    // `$model.features.x`: FeatureFlags is a value type, so each switch assigns a changed copy.
    fun update(change: (FeatureFlags) -> FeatureFlags) {
        model.features = change(model.features)
    }

    Form {
        FormSection(
            header = "Sensors",
            footer = "Motion feeds dead reckoning on the map, the GPS check's independent evidence and fused tracking's steps; without it the GPS check cannot reach \"trusted\". Compass gives dead reckoning its heading. The GPS check applies when the mesh restarts (below)." +
                // Android: UWB is shown unavailable with the reason, as on the Position tab.
                if (UWBRanging.supportsDistance) "" else " ${UWBRanging.unsupportedReason}",
        ) {
            ToggleRow("Motion (accelerometer, gyroscope)", features.motion) { on -> update { it.copy(motion = on) } }
            ToggleRow("Compass", features.compass) { on -> update { it.copy(compass = on) } }
            ToggleRow("UWB distances", model.uwbRangingEnabled, enabled = UWBRanging.supportsDistance) {
                model.setUWBRanging(it)
            }
            ToggleRow(
                "UWB positioning (anchor fixes)", model.uwbEnabled,
                enabled = model.isRunning && UWBRanging.supportsDistance,
            ) { model.setUWB(it) }
            ToggleRow("GPS check", model.gpsCheck) { model.gpsCheck = it }
            ToggleRow("Simulate losing GPS", model.simulateGPSLoss, enabled = model.positionChoice != PositionChoice.manual) {
                model.simulateGPSLoss = it
            }
        }

        FormSection(
            header = "Main map: phones without a position",
            footer = "Signal map: the dashboard's solver, UWB where measured and Bluetooth otherwise (Ranges picks one kind). Peer locator: GhostCore's per-phone engine. Particle filter: build 7's. The latter two use Bluetooth only. Calibration fits the radio model from UWB distances and placed phones (also on the Track tab). The Track tab compares the distance methods themselves.",
        ) {
            PickerRow("Placed by", PeerPlacement.entries, features.peerPlacement, { it.title }) { choice ->
                update { it.copy(peerPlacement = choice) }
            }
            SegmentedPickerRow(
                SignalRanges.entries, features.mainMapRanges, { it.title },
                enabled = features.peerPlacement == PeerPlacement.signalMap,
            ) { choice -> update { it.copy(mainMapRanges = choice) } }
            ToggleRow("Calibrate radio model", features.calibrateRadio) { on -> update { it.copy(calibrateRadio = on) } }
        }

        FormSection(
            header = "Phones that went silent",
            footer = "Model: GhostCore's movement-model prediction. Circle: the last spot, growing at walking pace. Off: the phone just ages out. Likely paths: the route model's routes with percentages.",
        ) {
            SegmentedPickerRow(PredictionMode.entries, features.prediction, { it.title }) { choice ->
                update { it.copy(prediction = choice) }
            }
            ToggleRow("Likely paths (route model)", features.likelyPaths) { on -> update { it.copy(likelyPaths = on) } }
        }

        FormSection(
            header = "Mesh",
            footer = "Fast updates publish and upload within 0.2 s of a move; off, once a second, with less Bluetooth traffic and battery. Every phone should use the same setting when comparing.",
        ) {
            ToggleRow("Fast updates (0.2 s)", features.fastUpdates) { on -> update { it.copy(fastUpdates = on) } }
            ToggleRow("Relay GPS check records", features.relayIntegrity) { on -> update { it.copy(relayIntegrity = on) } }
            ToggleRow("Keep screen awake", model.keepAwake) { model.keepAwake = it }
        }

        FormSection {
            ButtonRow("Restart the mesh (applies the GPS check)", enabled = model.isRunning) {
                model.stop()
                model.start()
            }
            ButtonRow("Reset features to defaults") { model.features = FeatureFlags() }
        }
    }
}
