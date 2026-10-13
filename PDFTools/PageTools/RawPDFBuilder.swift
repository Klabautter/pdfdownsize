import Foundation

/// Baut PDFs auf Byte-Ebene – für Fixtures, die PDFKit nicht erzeugen kann.
///
/// PDFKit schreibt Dokumente stets neu und normalisiert dabei genau die
/// Strukturen, auf die es in Regressionstests ankommt: gleiche Resource-Namen
/// für verschiedene Objekte, geteilte XObjects, Masken, Name-Trees, exotische
/// Filter. Solche Fixtures müssen deshalb direkt geschrieben werden.
///
/// Der Builder verwaltet Objektnummern und die xref-Tabelle; die Objektnummer
/// jedes Eintrags ist stabil und wird zurückgegeben, damit Tests exakt gegen
/// `PDFObjectID` prüfen können.
struct RawPDFBuilder {

    private struct Entry {
        let number: Int
        let body: Data
    }

    private var entries: [Entry] = []
    private var nextNumber = 1

    /// Fügt ein Objekt hinzu und liefert seine Objektnummer.
    @discardableResult
    mutating func addObject(_ body: String) -> Int {
        addObject(Data(body.utf8))
    }

    @discardableResult
    mutating func addObject(_ body: Data) -> Int {
        let number = nextNumber
        nextNumber += 1
        entries.append(Entry(number: number, body: body))
        return number
    }

    /// Fügt einen Stream mit korrekt berechnetem `/Length` hinzu.
    /// `dictionaryBody` ohne umschließende `<<`/`>>` und ohne `/Length`.
    @discardableResult
    mutating func addStream(dictionary dictionaryBody: String,
                            data streamData: Data) -> Int {
        var body = Data("<<\(dictionaryBody)/Length \(streamData.count)>>\nstream\n".utf8)
        body.append(streamData)
        body.append(Data("\nendstream".utf8))
        return addObject(body)
    }

    @discardableResult
    mutating func addStream(dictionary dictionaryBody: String,
                            content: String) -> Int {
        addStream(dictionary: dictionaryBody, data: Data(content.utf8))
    }

    /// Reserviert eine Objektnummer, bevor der Inhalt bekannt ist
    /// (nötig für zyklische Verweise wie /Parent).
    mutating func reserveNumber() -> Int {
        let number = nextNumber
        nextNumber += 1
        return number
    }

    /// Trägt einen zuvor reservierten Platz nach.
    mutating func fill(_ number: Int, _ body: String) {
        entries.append(Entry(number: number, body: Data(body.utf8)))
    }

    /// Baut eine wohlgeformte Seite.
    ///
    /// `/Resources` ist laut PDF-Spezifikation ein Pflichteintrag (vererbbar).
    /// Fehlt er, meldet qpdf „Resources is missing or invalid; repairing" –
    /// und `pdfcore_check` wertet jede Warnung als Fehlschlag. Eine Fixture,
    /// die schon selbst Warnungen erzeugt, kann nichts über die Engine
    /// aussagen; deshalb geht jede Seite durch diesen Helfer.
    @discardableResult
    mutating func addPage(parent: Int,
                          mediaBox: String = "[0 0 612 792]",
                          resources: String = "<<>>",
                          contents: Int? = nil,
                          extra: String = "") -> Int {
        var body = "<</Type/Page/Parent \(parent) 0 R/MediaBox\(mediaBox)"
            + "/Resources \(resources)"
        if let contents { body += "/Contents \(contents) 0 R" }
        body += extra + ">>"
        return addObject(body)
    }

    /// Trägt eine wohlgeformte Seite an einer reservierten Nummer nach.
    mutating func fillPage(_ number: Int,
                           parent: Int,
                           mediaBox: String = "[0 0 612 792]",
                           resources: String = "<<>>",
                           contents: Int? = nil,
                           extra: String = "") {
        var body = "<</Type/Page/Parent \(parent) 0 R/MediaBox\(mediaBox)"
            + "/Resources \(resources)"
        if let contents { body += "/Contents \(contents) 0 R" }
        body += extra + ">>"
        fill(number, body)
    }

    /// Serialisiert das Dokument mit klassischer xref-Tabelle.
    func build(rootObject: Int) -> Data {
        var data = Data("%PDF-1.7\n%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n".utf8)
        var offsets: [Int: Int] = [:]

        for entry in entries.sorted(by: { $0.number < $1.number }) {
            offsets[entry.number] = data.count
            data.append(Data("\(entry.number) 0 obj\n".utf8))
            data.append(entry.body)
            data.append(Data("\nendobj\n".utf8))
        }

        let startxref = data.count
        let size = (entries.map(\.number).max() ?? 0) + 1
        data.append(Data("xref\n0 \(size)\n".utf8))
        data.append(Data("0000000000 65535 f \n".utf8))
        for number in 1..<size {
            if let offset = offsets[number] {
                data.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
            } else {
                // Lücken in der Nummerierung als frei markieren – sonst zeigt
                // die Tabelle auf Offset 0 und qpdf meldet einen Strukturfehler.
                data.append(Data("0000000000 65535 f \n".utf8))
            }
        }
        data.append(Data("trailer\n<</Size \(size)/Root \(rootObject) 0 R>>\n".utf8))
        data.append(Data("startxref\n\(startxref)\n%%EOF\n".utf8))
        return data
    }
}
