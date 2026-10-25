package com.hackathonmapper.meshcore

// Port of ios/MeshCore/Sources/MeshCore/Positioning/MotionProcessing.swift lives in PositioningMath.kt, section
// "MARK: MotionProcessing.swift". Swift adds these types to `enum Positioning` with `extension Positioning`;
// Kotlin cannot add nested types to `object Positioning` from another file (and has no nested type
// aliases), so the whole namespace is declared in one file to keep every `Positioning.X` name.
