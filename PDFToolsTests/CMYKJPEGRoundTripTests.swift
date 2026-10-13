import Testing
import Foundation
import CoreGraphics
@testable import PDFTools

/// Festgenagelt: ImageIO kehrt CMYK beim JPEG-Rundlauf UM.
///
/// Gemessen, nicht vermutet. Ein 8×8-Feld aus reinem Cyan (C=255, M=Y=K=0)
/// kommt als (0, 255, 255, 255) zurück – exakt invertiert.
///
/// WELCHE SEITE INVERTIERT
///
/// Der Rundlauf allein beantwortet das nicht, und der Unterschied ist
/// entscheidend. Eine zweite Messung an einem ECHTEN, von Adobe erzeugten
/// CMYK-JPEG aus dem IPCC-Bericht (Objekt 45964, 1172×1562) klärt es: Der
/// häufigste Bildpunkt ist (0, 0, 0, 0) bei 63 % der Stichprobe – also
/// weiss, wie es dem Hintergrund einer Abbildung entspricht.
///
/// Der DEKODIERER arbeitet demnach richtig: Er erkennt den Adobe-APP14-
/// Marker und dreht die gespeicherten Werte zurück. Es ist der KODIERER,
/// der die Werte unverändert schreibt und den Marker setzt – wodurch sie
/// beim nächsten Lesen gedreht werden.
///
/// Daraus folgt die Politik dieses Projekts:
///   LESEN von CMYK-JPEGs ist sicher – der verlustfreie Pfad bekommt
///     korrekte Farben und darf diese Bilder anfassen.
///   SCHREIBEN als CMYK-JPEG ist es NICHT – siehe unten.
///
/// WARUM DAS HIER STEHT
///
/// Es ist eine Falle mit stillem Ausgang. Wer ein CMYK-Bild durch
/// `ImageResampler.encodeJPEG` schickt und das Ergebnis als `/DeviceCMYK`
/// ohne `/Decode [1 0 1 0 1 0 1 0]` ins Dokument legt, erhält ein Bild mit
/// vertauschten Farben – kein Absturz, keine Meldung, nur falsche Farben.
/// Heute schützt davor allein `allowsLossyReplacement == false` für CMYK.
/// Fiele diese Regel unbedacht, gäbe es ohne diesen Test keine Warnung.
///
/// Ändert Apple das Verhalten, schlägt dieser Test fehl – und dann ist eine
/// Entscheidung fällig, keine stille Anpassung.
@Suite struct CMYKJPEGRoundTripTests {

    /// Baut ein einfarbiges CMYK-Bild aus den vier Werten.
    static func cmykImage(_ c: UInt8, _ m: UInt8, _ y: UInt8, _ k: UInt8,
                          size: Int = 8) -> CGImage? {
        var px = [UInt8](repeating: 0, count: size * size * 4)
        for i in 0..<(size * size) {
            px[i * 4 + 0] = c; px[i * 4 + 1] = m
            px[i * 4 + 2] = y; px[i * 4 + 3] = k
        }
        guard let space = CGColorSpace(name: CGColorSpace.genericCMYK),
              let ctx = CGContext(data: &px, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        return ctx.makeImage()
    }

    static func firstPixel(_ image: CGImage) -> [UInt8]? {
        guard let data = image.dataProvider?.data as Data?, data.count >= 4 else { return nil }
        return Array(data.prefix(4))
    }

    @Test func cmykBleibtVierKanaligUeberDenRundlauf() throws {
        let image = try #require(Self.cmykImage(255, 0, 0, 0))
        let jpeg = try #require(ImageResampler.encodeJPEG(image, quality: 0.95))
        let back = try #require(ImageResampler.decodeJPEG(jpeg))
        #expect(back.colorSpace?.numberOfComponents == 4,
                "ImageIO hat den Farbraum gewechselt – die Annahme unten trägt nicht mehr")
    }

    /// Der eigentliche Befund.
    @Test(arguments: [
        (UInt8(255), UInt8(0),   UInt8(0),   UInt8(0)),     // Cyan
        (UInt8(0),   UInt8(255), UInt8(0),   UInt8(0)),     // Magenta
        (UInt8(0),   UInt8(0),   UInt8(0),   UInt8(255)),   // Schwarz
        (UInt8(0),   UInt8(0),   UInt8(0),   UInt8(0)),     // Weiss
    ])
    func rundlaufKehrtCMYKUm(_ color: (UInt8, UInt8, UInt8, UInt8)) throws {
        let (c, m, y, k) = color
        let image = try #require(Self.cmykImage(c, m, y, k))
        let jpeg = try #require(ImageResampler.encodeJPEG(image, quality: 1.0))
        let back = try #require(ImageResampler.decodeJPEG(jpeg))
        let got = try #require(Self.firstPixel(back))
        let expected = [255 &- c, 255 &- m, 255 &- y, 255 &- k]

        // JPEG bleibt verlustbehaftet, auch bei Qualität 1.0 – daher ein
        // Toleranzband statt exakter Gleichheit. Es ist eng genug, dass eine
        // NICHT invertierte Rückgabe (Abstand 255) sicher auffiele.
        for i in 0..<4 {
            let delta = abs(Int(got[i]) - Int(expected[i]))
            #expect(delta <= 8, """
                Kanal \(i): erwartet \(expected[i]) (invertiert von \(color)), \
                erhalten \(got[i]). Kehrt ImageIO CMYK nicht mehr um, ist die \
                Sperre für verlustbehaftetes CMYK neu zu bewerten.
                """)
        }
    }

    /// Die Gegenprobe zum Rundlauf: Was ImageIO SELBST geschrieben hat,
    /// liest es gedreht zurück. Ein Bild, dessen Kanäle voll sind, kommt
    /// also leer zurück – das ist Weiss in CMYK.
    ///
    /// Genau daran hängt die Sicherheit des verlustfreien Pfads: Erkennt
    /// der Dekodierer den Adobe-Marker nicht mehr, schlägt dieser Test
    /// fehl, und die Freigabe der Vorgabe-Decode-Arrays (siehe
    /// `DefaultDecodeArrayTests`) wäre neu zu bewerten.
    @Test func dekodiererDrehtAdobeWerteZurueck() throws {
        // Volle Kanäle hinein …
        let image = try #require(Self.cmykImage(255, 255, 255, 255))
        let jpeg = try #require(ImageResampler.encodeJPEG(image, quality: 1.0))
        #expect(jpeg.range(of: Data("Adobe".utf8)) != nil,
                "ohne Adobe-Marker greift die Konvention gar nicht")
        let back = try #require(ImageResampler.decodeJPEG(jpeg))
        let got = try #require(Self.firstPixel(back))
        // … leere Kanäle heraus: der Dekodierer hat gedreht.
        for (i, value) in got.enumerated() {
            #expect(value <= 8, """
                Kanal \(i) kam als \(value) zurück statt nahe 0 – der \
                Dekodierer wendet die Adobe-Konvention nicht mehr an.
                """)
        }
    }

    /// Die Sperre, die uns vor dem Fehler auf der SCHREIBSEITE bewahrt.
    /// Fällt sie, muss jemand vorher hier vorbei.
    @Test func cmykBleibtVonVerlustbehafteterErsetzungAusgenommen() {
        #expect(PDFColorSpaceDescriptor.deviceCMYK.allowsLossyReplacement == false)
        #expect(PDFColorSpaceDescriptor.iccBased(components: 4).allowsLossyReplacement == false)
    }
}
