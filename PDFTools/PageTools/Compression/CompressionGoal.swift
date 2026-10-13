import Foundation

// MARK: - Masterplan §5.1 – CompressionGoal

/// Dokumentweites Optimierungsziel. Der Planner wählt pro Ressource lokal
/// den kleinsten Candidate, der die Preset-Floors hält (§5.8 Phase A); das
/// Ziel bestimmt, WELCHE Floors gelten und steuert ab V2-6 den globalen
/// Budget-Optimizer.
enum CompressionGoal: Equatable, Codable, Sendable {
    /// Kleinste sichere Datei (Preset „Klein“).
    case smallest
    /// Ausgewogen (Preset „Smart“, Voreinstellung).
    case balanced
    /// Beste Qualität innerhalb der Floors (Preset „Qualität“).
    case bestQuality
    /// Zieldateigröße in Bytes (V2-6; UI-Verdrahtung folgt mit dieser Phase).
    case targetBytes(Int64)
}

extension CompressionGoal {

    /// true für `.targetBytes` – der Zielgrößen-Optimizer (V2-6, §12) läuft
    /// nur mit diesem Ziel; alle anderen Ziele bleiben Preset-Politik.
    var isTargetSize: Bool {
        if case .targetBytes = self { return true }
        return false
    }

    /// Mapping aus dem UI-Modus (§5.1): Klein → smallest, Smart → balanced,
    /// Qualität → bestQuality. Custom bleibt Parameter-Override mit
    /// unverhandelbarer Safety Floor und läuft als balanced.
    init(mode: CompressionMode) {
        switch mode {
        case .small: self = .smallest
        case .smart: self = .balanced
        case .quality: self = .bestQuality
        case .custom: self = .balanced
        }
    }

    /// Mapping aus den Bildoptionen – die Form, die der Planner benutzt,
    /// weil er Optionen erhält, nicht den UI-Modus. Die SSIM-Zusage ist die
    /// Preset-Kennung (dieselbe Ableitung wie `QualityGatePreset`);
    /// feste Qualität (Custom) fällt auf balanced.
    init(imageOptions: ImageCompressionOptions) {
        switch imageOptions.ssimThreshold {
        case ImageCompressionOptions.small.ssimThreshold: self = .smallest
        case ImageCompressionOptions.smart.ssimThreshold: self = .balanced
        case ImageCompressionOptions.quality.ssimThreshold: self = .bestQuality
        default: self = .balanced
        }
    }
}
