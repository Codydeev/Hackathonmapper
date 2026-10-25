package com.hackathonmapper.meshcore

// The agents' engines in the pipeline's slots. Their files stay theirs; only the conformances live here.
//
// Swift adds `extension GNSSIntegrityMonitor: GhostIntegrityEngine {}` in this file. Kotlin cannot
// add an interface to a class from outside it, so the conformance is declared on the class itself
// (`class GNSSIntegrityMonitor(...) : GhostIntegrityEngine` in GNSSIntegrity.kt, PORTING.md "Types").
// This file stays so the Swift and Kotlin trees list the same files.
