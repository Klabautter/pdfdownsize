import Foundation

/// Final Core Hardening, Phase 3 – kuratierte Multi-Source-Merges.
///
/// Der bisherige Merge-Test verdoppelte Seiten DERSELBEN Quelle. Damit blieb
/// ungeprüft, was beim Zusammenführen wirklich schwierig ist: kollidierende
/// Formularfeldnamen, Navigationsstrukturen aus mehreren Dokumenten,
/// unterschiedliche Seitengrössen und Rotationen, Fonts verschiedener
/// Erzeuger.
///
/// Die Szenarien sind fest definiert, nicht zufällig gezogen: Ein Fehlschlag
/// muss ohne Seed reproduzierbar sein (Plan 3.4).
enum MultiSourceScenarios {

    /// Eine Quelle innerhalb eines Szenarios.
    struct SourceSpec: Sendable {
        /// Pfad relativ zur Korpuswurzel.
        let relativePath: String
        /// Welche Seiten übernommen werden (0-basiert).
        let pages: [Int]
    }

    /// Ein Szenario samt Erwartung.
    ///
    /// Das Manifest ist die Erwartung: Ausgabeseite *i* zeigt Quelle
    /// `expectedOrigin[i].source`, Seite `expectedOrigin[i].page`. Ohne diese
    /// Zuordnung könnte der Vergleich nur zählen – und Zählen beweist nicht,
    /// dass die richtige Seite an der richtigen Stelle steht.
    struct Scenario: Sendable {
        let name: String
        /// Wofür dieses Szenario steht – erscheint im Report.
        let category: String
        let sources: [SourceSpec]

        /// Ausgabeseite → (Quellindex, Seitenindex in der Quelle).
        var expectedOrigin: [(source: Int, page: Int)] {
            var result: [(source: Int, page: Int)] = []
            for (index, spec) in sources.enumerated() {
                for page in spec.pages { result.append((source: index, page: page)) }
            }
            return result
        }
    }

    private static func s(_ path: String, _ pages: [Int]) -> SourceSpec {
        SourceSpec(relativePath: path, pages: pages)
    }

    /// Die kuratierten Szenarien.
    ///
    /// Abgedeckt sind die in Plan 3.2 geforderten Kategorien: zwei und drei
    /// Quellen, gleicher und verschiedener Erzeuger, kollidierende
    /// Feldnamen, unterschiedliche Seitengrössen und Rotationen, Outlines in
    /// einer und in allen Quellen, Named Destinations, Page Labels,
    /// Annotationen, interne Verweise, Type1-/Subset-Fonts.
    static let all: [Scenario] = [
        // --- Formulare: kollidierende Feldnamen --------------------------
        Scenario(name: "forms-same-field-names", category: "form collision",
                 sources: [s("Golden/forms/form-widgets.pdf", [0]),
                           s("Golden/forms/form-widgets.pdf", [0])]),
        Scenario(name: "forms-hierarchy-plus-widgets", category: "form collision",
                 sources: [s("Golden/forms/form-hierarchy.pdf", [0]),
                           s("Golden/forms/form-widgets.pdf", [0])]),
        Scenario(name: "forms-three-sources", category: "form collision · 3 sources",
                 sources: [s("Golden/forms/form-widgets.pdf", [0]),
                           s("Golden/forms/form-hierarchy.pdf", [0]),
                           s("Golden/forms/utf16-field-names.pdf", [0])]),
        Scenario(name: "forms-plus-signature", category: "form collision",
                 sources: [s("Golden/forms/form-widgets.pdf", [0]),
                           s("Golden/forms/signature-field.pdf", [0])]),

        // --- Navigation ---------------------------------------------------
        Scenario(name: "outline-in-one-source", category: "navigation",
                 sources: [s("Golden/navigation/nested-outline.pdf", [0]),
                           s("Golden/text/multi-paragraph.pdf", [0])]),
        Scenario(name: "outline-in-all-sources", category: "navigation",
                 sources: [s("Golden/navigation/nested-outline.pdf", [0]),
                           s("Golden/navigation/outline-internal-link.pdf", [0])]),
        Scenario(name: "named-destinations-merge", category: "navigation",
                 sources: [s("Golden/navigation/named-destinations.pdf", [0]),
                           s("Golden/navigation/outline-internal-link.pdf", [0])]),
        Scenario(name: "internal-links-plus-external", category: "navigation",
                 sources: [s("Golden/navigation/outline-internal-link.pdf", [0]),
                           s("Golden/navigation/external-links.pdf", [0])]),
        Scenario(name: "annotations-merge", category: "annotations",
                 sources: [s("Golden/navigation/external-links.pdf", [0]),
                           s("Golden/navigation/rasterized-annotations.pdf", [0])]),
        Scenario(name: "navigation-three-sources", category: "navigation · 3 sources",
                 sources: [s("Golden/navigation/nested-outline.pdf", [0]),
                           s("Golden/navigation/named-destinations.pdf", [0]),
                           s("Golden/navigation/external-links.pdf", [0])]),

        // --- Page Labels ---------------------------------------------------
        Scenario(name: "page-labels-plus-plain", category: "page labels",
                 sources: [s("Golden/page-labels/roman-then-decimal.pdf", [0, 1]),
                           s("Golden/text/multi-paragraph.pdf", [0])]),
        Scenario(name: "page-labels-both-sides", category: "page labels",
                 sources: [s("Golden/text/multi-paragraph.pdf", [0]),
                           s("Golden/page-labels/roman-then-decimal.pdf", [0])]),

        // --- Geometrie ------------------------------------------------------
        Scenario(name: "different-page-sizes", category: "geometry",
                 sources: [s("Golden/geometry/mixed-page-sizes.pdf", [0]),
                           s("Golden/text/multi-paragraph.pdf", [0])]),
        Scenario(name: "different-rotations", category: "geometry",
                 sources: [s("Golden/geometry/rotated.pdf", [0]),
                           s("Golden/geometry/mixed-rotation.pdf", [0])]),
        Scenario(name: "cropbox-plus-normal", category: "geometry",
                 sources: [s("Golden/geometry/cropbox-offset.pdf", [0]),
                           s("Golden/text/vector-text.pdf", [0])]),
        Scenario(name: "geometry-three-sources", category: "geometry · 3 sources",
                 sources: [s("Golden/geometry/rotated.pdf", [0]),
                           s("Golden/geometry/mixed-page-sizes.pdf", [0]),
                           s("Golden/geometry/cropbox-offset.pdf", [0])]),

        // --- Fonts ------------------------------------------------------------
        Scenario(name: "multiple-fonts-plus-form", category: "fonts",
                 sources: [s("Golden/text/multiple-fonts.pdf", [0]),
                           s("Golden/forms/form-widgets.pdf", [0])]),
        Scenario(name: "vector-text-plus-images", category: "fonts",
                 sources: [s("Golden/text/vector-text.pdf", [0]),
                           s("Golden/images/photo-high-dpi.pdf", [0])]),
        Scenario(name: "tiny-text-plus-multi", category: "fonts",
                 sources: [s("Golden/text/tiny-text.pdf", [0]),
                           s("Golden/text/multi-paragraph.pdf", [0])]),

        // --- Struktur und geteilte Ressourcen ---------------------------------
        Scenario(name: "shared-xobjects-two-docs", category: "shared resources",
                 sources: [s("Golden/shared-xobjects/shared-image-two-pages.pdf", [0, 1]),
                           s("Golden/shared-xobjects/same-name-different-objects.pdf", [0])]),
        Scenario(name: "object-streams-plus-plain", category: "structure",
                 sources: [s("Golden/structure/object-streams.pdf", [0]),
                           s("Golden/text/multi-paragraph.pdf", [0])]),
        Scenario(name: "complex-combination-merge", category: "structure · 3 sources",
                 sources: [s("Golden/structure/complex-combination.pdf", [0]),
                           s("Golden/structure/multi-content-types.pdf", [0]),
                           s("Golden/text/vector-text.pdf", [0])]),
        Scenario(name: "attachment-plus-form", category: "attachments",
                 sources: [s("Golden/attachments/single-embedded-file.pdf", [0]),
                           s("Golden/forms/form-widgets.pdf", [0])]),

        // --- Erzeuger-Mix (echte Dokumente) -------------------------------------
        Scenario(name: "producer-mix-latex-adobe", category: "producer mix",
                 sources: [s("RealWorld/arXiv/1409.1556.pdf", [0]),
                           s("RealWorld/IRS/f1023ez.pdf", [0])]),
        Scenario(name: "producer-mix-three", category: "producer mix · 3 sources",
                 sources: [s("RealWorld/arXiv/1409.1556.pdf", [0]),
                           s("RealWorld/IRS/f1023ez.pdf", [0]),
                           s("RealWorld/NIST/SP.800-207.pdf", [0])]),
    ]
}
