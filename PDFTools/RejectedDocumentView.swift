import SwiftUI

/// Masterplan B1: Die Dokumentfläche für eine Datei, die sich nicht
/// verarbeiten lässt – Symbol, Satz, nächster Schritt. Kein Pult, keine
/// Schätzung, kein Hauptknopf: Es gibt nichts zu starten.
///
/// Dieselbe Fläche in Komprimieren, OCR und Konvertieren.
struct RejectedDocumentView: View {
    let fileName: String
    let verdict: DocumentProbe.Verdict
    let onChooseOther: () -> Void
    let onClose: () -> Void
    /// Masterplan B2: Entsperren anbieten (nur bei `.locked`). nil = das
    /// Werkzeug kann keine gesperrten PDFs verarbeiten.
    var onUnlock: ((String) -> Void)? = nil
    var passwordError: String? = nil
    var isUnlocking = false
    /// Bleibt das Passwort im Ergebnis erhalten? false für Bild-Export
    /// (Konvertieren) und Mehr-Quellen-Zusammenfügen (Organisieren).
    var preservesPassword = true
    /// Beschriftung des Ausweichknopfs (Organisieren: „Überspringen“).
    var chooseOtherLabel: String? = nil

    @State private var password = ""
    @FocusState private var passwordFocused: Bool

    private var icon: String {
        switch verdict {
        case .locked: return "lock.doc"
        case .empty: return "doc"
        case .missing: return "questionmark.folder"
        case .unreadable, .ok: return "exclamationmark.triangle"
        }
    }

    var body: some View {
        ContentUnavailableView {
            Label(verdict.title, systemImage: icon)
                .symbolRenderingMode(.hierarchical)
        } description: {
            VStack(spacing: 6) {
                Text(fileName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verdict == .locked && onUnlock != nil
                     ? (preservesPassword
                        ? String(localized: "Mit dem Passwort lässt sie sich verarbeiten. Das Ergebnis bleibt mit demselben Passwort geschützt.")
                        : String(localized: "Mit dem Passwort lässt sie sich für diese Verarbeitung entsperren."))
                     : verdict.detail)
            }
        } actions: {
            VStack(spacing: 14) {
                if verdict == .locked, let onUnlock {
                    // Das Passwort bleibt im Speicher – nie gesichert, nie protokolliert.
                    HStack(spacing: 8) {
                        SecureField("Passwort", text: $password)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                            .focused($passwordFocused)
                            .onSubmit { if !password.isEmpty { onUnlock(password) } }
                        Button("Entsperren") { onUnlock(password) }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(password.isEmpty || isUnlocking)
                    }
                    if let passwordError {
                        Text(passwordError).font(.callout).foregroundStyle(Theme.warningText)
                    }
                }
                HStack(spacing: 12) {
                    Button("Schließen", action: onClose)
                        .buttonStyle(.bordered)
                    if verdict == .locked && onUnlock != nil {
                        Button(chooseOtherLabel ?? String(localized: "Andere PDF wählen …"), action: onChooseOther)
                            .buttonStyle(.bordered)
                    } else {
                        Button(chooseOtherLabel ?? String(localized: "Andere PDF wählen …"), action: onChooseOther)
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .controlSize(.large)
            .onAppear { if verdict == .locked { passwordFocused = true } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .accessibilityElement(children: .contain)
    }
}
