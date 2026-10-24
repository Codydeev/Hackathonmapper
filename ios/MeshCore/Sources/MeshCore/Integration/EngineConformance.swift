import Foundation

// The agents' engines in the pipeline's slots. Their files stay theirs; only the conformances live here.

/// GNSS trust agent's monitor (GNSSIntegrity.swift) has exactly the slot's methods.
extension GNSSIntegrityMonitor: GhostIntegrityEngine {}
