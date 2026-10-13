import Testing

/// Zeitgrenzen der Testsuite – eine Stelle, eine Begründung.
///
/// Die Grenzen existieren, um HÄNGER zu fangen: Tests, die einen fremden
/// Prozess starten oder auf Dateien warten, können sonst unbegrenzt stehen
/// (Masterplan Befund 7). Ein Hänger ist unendlich – den fängt auch eine
/// weite Grenze.
///
/// Sie sind ausdrücklich KEINE Leistungszusage. Eine Minute war dafür zu eng:
/// Swift Testing misst die Zeit ab Erzeugung des Tests, nicht ab Beginn
/// seiner Arbeit. Läuft parallel ein rechenschwerer Test – im Debug-Build
/// kostet ein SSIM-Vergleich über vier Seiten bei 150 DPI rund eine Minute –,
/// dann misst die Grenze die Arbeit ANDERER Tests. Gemessen wurde genau das:
/// `everyVisibleSettingReachesTheOptions` lief allein in 0,001 s und riss in
/// der vollen Suite exakt 60,000 s, während die gleichzeitig wartenden
/// Nachbartests bei 59,626 s durchkamen. Dasselbe traf danach
/// `reportNeverComesFromASingleShard` (0,006 s allein).
///
/// Fünf Minuten liegen deutlich über allem, was hier legitim dauert, und
/// fangen einen echten Hänger weiterhin.
extension Trait where Self == TimeLimitTrait {
    static var hangGuard: Self { .timeLimit(.minutes(5)) }
}

/// Zeitgrenze für MESSLÄUFE, nicht für Tests.
///
/// `hangGuard` sagt „fünf Minuten liegen deutlich über allem, was hier
/// legitim dauert". Für das Genauigkeitslabor stimmt das nicht: Es fährt den
/// gesamten Korpus durch fünf Voreinstellungen – 1425 vollständige
/// Kompressionen. Es an `hangGuard` zu hängen war ein Fehler; der erste Lauf
/// brach nach genau 300 Sekunden mitten in der Messung ab.
///
/// Solche Läufe sind keine Unit-Tests und laufen nur auf ausdrückliche
/// Anforderung über ihr Startskript. Die Grenze fängt trotzdem einen echten
/// Stillstand.
///
/// DERSELBE FEHLER EINE EBENE HÖHER – 30.08.2026
///
/// Sechzig Minuten reichten auch nicht mehr. Der Lauf brach bei exakt
/// 3600,000 s ab, nachdem 1000 von 1475 Kompressionen erledigt waren.
/// Ursache ist nicht der Code, sondern der Korpus: Seit der IPCC-Bericht
/// (404 MB, 2409 Seiten) darin liegt, kostet ALLEIN dieses eine Dokument
/// über alle fünf Voreinstellungen 78,8 Minuten – mehr als die gesamte
/// bisherige Grenze.
///
/// Die neue Grenze steht auf gemessener Grundlage: 1000 Kompressionen in
/// 60 Minuten ergeben rund 90 Minuten für den vollen Lauf. Drei Stunden
/// lassen Luft für eine ausgelastete Maschine und fangen einen echten
/// Stillstand weiterhin.
///
/// Die eigentliche Lösung wäre, das Labor wie den Korpuslauf in Chargen zu
/// fahren – dann läge es bei etwa 15 Minuten, und diese Grenze müsste nie
/// wieder angefasst werden. Das ist eigene Arbeit und steht noch aus.
extension Trait where Self == TimeLimitTrait {
    static var measurementRun: Self { .timeLimit(.minutes(180)) }
}
