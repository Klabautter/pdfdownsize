import Foundation

/// Masterplan D5 (Fuzz-Fund crash-100406): Seitenmaße in Pixel umrechnen,
/// ohne dass eine absurde Box (mutierte /MediaBox, NaN, 1e300) den Prozess
/// beendet. `Int(Double)` bricht in Swift bei Überlauf oder NaN hart ab
/// (SIGTRAP) – die Render-Stichprobe stürzte daran ab.
enum PixelExtent {
    /// Obergrenze für eine Kante in Pixeln, weit über jedem sinnvollen Raster.
    static let maximumEdge = 1_000_000

    /// `points * scale`, gerundet; nil bei NaN, Unendlich, ≤ 0 oder über der Grenze.
    static func edge(_ points: Double, scale: Double) -> Int? {
        let value = (points * scale).rounded()
        guard value.isFinite, value > 0, value <= Double(maximumEdge) else { return nil }
        return Int(value)
    }
}
