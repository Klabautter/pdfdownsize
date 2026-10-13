import Testing
import Foundation
@testable import PDFTools

/// Ein `/Decode`-Array, das der VORGABE entspricht, bewirkt nichts – und
/// darf deshalb nichts sperren.
///
/// GEMESSEN, NICHT VERMUTET
///
/// Im IPCC-Bericht (404 MB) tragen 39 210 Bilder ein `/Decode`-Array. Nach
/// Art aufgeschlüsselt:
///
///     Identität, 4 Kanäle    36 510 Stück   38,7 MB
///     [0 255] (Indexed)       1 873 Stück    2,9 MB
///     Identität, 1 Kanal        620 Stück    2,1 MB
///     echte Invertierung        207 Stück    0,1 MB
///
/// 37 130 Bilder mit zusammen 40,8 MB werden also von einer Abbildung
/// gesperrt, die keine ist: `[0 1 0 1 0 1 0 1]` bildet jeden Wert auf sich
/// selbst ab. Der Erzeuger hat die Vorgabe nur ausgeschrieben – viele tun
/// das.
///
/// Die Vorgaben stehen in ISO 32000-1, Tabelle 89:
///   - Device*/Cal*/ICCBased:  [0 1] je Komponente
///   - Indexed:                [0  2^BitsPerComponent − 1]
///   - ImageMask:              [0 1]
@Suite struct DefaultDecodeArrayTests {

    static func resource(colorSpace: PDFColorSpaceDescriptor,
                         decode: [Double],
                         filter: PDFImageFilter = .dct,
                         bitsPerComponent: Int = 8,
                         isImageMask: Bool = false) -> PDFImageResource {
        PDFImageResource(
            objectID: PDFObjectID(objectNumber: 1, generation: 0),
            width: 800, height: 600, bitsPerComponent: bitsPerComponent,
            colorSpace: colorSpace, filters: [filter], unknownFilters: [],
            hasSoftMask: false, hasExplicitMask: false,
            hasColorKeyMask: false, isImageMask: isImageMask,
            decodeArray: decode, encodedByteCount: 200_000,
            placements: [PDFImagePlacement(pageIndex: 0, resourceName: "/Im1",
                                           placedWidthPoints: 200,
                                           placedHeightPoints: 150)])
    }

    // MARK: - Der eigentliche Befund

    /// Der Fall aus dem Korpus: CMYK-JPEG mit ausgeschriebener Vorgabe.
    @Test func vorgabeArrayAufCMYKJPEGSperrtNicht() {
        let r = Self.resource(colorSpace: .deviceCMYK,
                              decode: [0, 1, 0, 1, 0, 1, 0, 1])
        #expect(r.hasEffectiveDecodeArray == false,
                "Die Identität wurde nicht als Vorgabe erkannt")
        #expect(r.transformCapability != .decodeArrayUnsupported, """
            Ein Vorgabe-Array sperrt weiterhin. Im IPCC-Bericht betrifft das \
            36 510 Bilder mit 38,7 MB.
            """)
    }

    @Test func vorgabeArrayAufGrauJPEGSperrtNicht() {
        let r = Self.resource(colorSpace: .deviceGray, decode: [0, 1])
        #expect(r.hasEffectiveDecodeArray == false)
        #expect(r.transformCapability != .decodeArrayUnsupported)
    }

    /// `[0 255]` ist bei Indexed die Vorgabe (0 … 2^8−1), nicht eine
    /// Abbildung. 1 873 Bilder im Korpus.
    @Test func indexedVorgabeIstDieHivalSpanne() {
        let r = Self.resource(colorSpace: .indexed, decode: [0, 255],
                              filter: .flate, bitsPerComponent: 8)
        #expect(r.hasEffectiveDecodeArray == false)
    }

    @Test(arguments: [(1, 1.0), (2, 3.0), (4, 15.0), (8, 255.0)])
    func indexedVorgabeHaengtAnDerBittiefe(_ c: (bits: Int, hival: Double)) {
        let passend = Self.resource(colorSpace: .indexed, decode: [0, c.hival],
                                    filter: .flate, bitsPerComponent: c.bits)
        #expect(passend.hasEffectiveDecodeArray == false,
                "[0 \(c.hival)] ist bei \(c.bits) bit die Vorgabe")
        let unpassend = Self.resource(colorSpace: .indexed, decode: [0, 7],
                                      filter: .flate, bitsPerComponent: c.bits)
        if c.bits != 3 {
            #expect(unpassend.hasEffectiveDecodeArray == (c.hival != 7))
        }
    }

    // MARK: - Die Gegenprobe: echte Arrays bleiben gesperrt

    /// Eine echte Invertierung ändert die Tonwerte. Sie MUSS weiter sperren,
    /// solange wir sie nicht anwenden – 207 Bilder im Korpus.
    @Test func echteInvertierungSperrtWeiterhin() {
        let r = Self.resource(colorSpace: .deviceGray, decode: [1, 0])
        #expect(r.hasEffectiveDecodeArray == true)
        #expect(r.transformCapability == .decodeArrayUnsupported)
    }

    @Test func teilweiseInvertierungSperrtWeiterhin() {
        // Nur ein Kanal gedreht – das ist keine Vorgabe.
        let r = Self.resource(colorSpace: .deviceRGB, decode: [0, 1, 1, 0, 0, 1])
        #expect(r.hasEffectiveDecodeArray == true)
        #expect(r.transformCapability == .decodeArrayUnsupported)
    }

    @Test func gestauchteSpanneSperrtWeiterhin() {
        let r = Self.resource(colorSpace: .deviceGray, decode: [0.2, 0.8])
        #expect(r.hasEffectiveDecodeArray == true)
    }

    /// Ein Array mit falscher Länge ist nicht die Vorgabe – und wir wissen
    /// nicht, was es bedeutet. Im Zweifel sperren.
    @Test func falscheLaengeSperrtWeiterhin() {
        let r = Self.resource(colorSpace: .deviceCMYK, decode: [0, 1, 0, 1])
        #expect(r.hasEffectiveDecodeArray == true)
    }

    /// Ohne bekannte Komponentenzahl lässt sich die Vorgabe nicht bilden.
    @Test func unbekannterFarbraumSperrtWeiterhin() {
        let r = Self.resource(colorSpace: .deviceN, decode: [0, 1, 0, 1])
        #expect(r.hasEffectiveDecodeArray == true)
    }

    @Test func keinArrayIstKeinArray() {
        let r = Self.resource(colorSpace: .deviceCMYK, decode: [])
        #expect(r.hasEffectiveDecodeArray == false)
        #expect(r.transformCapability != .decodeArrayUnsupported)
    }

    /// Bei einer Schablone ist [0 1] die Vorgabe, [1 0] kehrt sie um.
    @Test func schabloneHatEigeneVorgabe() {
        let vorgabe = Self.resource(colorSpace: .none, decode: [0, 1],
                                    filter: .ccitt, bitsPerComponent: 1,
                                    isImageMask: true)
        #expect(vorgabe.hasEffectiveDecodeArray == false)
        let gedreht = Self.resource(colorSpace: .none, decode: [1, 0],
                                    filter: .ccitt, bitsPerComponent: 1,
                                    isImageMask: true)
        #expect(gedreht.hasEffectiveDecodeArray == true)
    }
}
