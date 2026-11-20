# dpm-monitor – Design

Überwachung von Microsoft System Center DPM auf On-Premises-Servern bei Kunden der gimas GmbH.

Dieses Dokument hat drei Ebenen mit unterschiedlicher Verbindlichkeit:

1. **Ziele und Invarianten**: fest. Änderungen nur nach Rücksprache.
2. **Bekannte Fakten und Fallstricke**: Wissen, das schon einmal teuer war. Gilt, bis es widerlegt ist.
3. **Ausgangshypothesen**: der aktuelle Plan, entstanden ohne Implementierung und ohne echte Daten.
   Darf mit Begründung geändert werden; die Änderung kommt ins Entscheidungslog.

## 1. Ziele und Invarianten

**Ziel:** Alarm, wenn Backups eine Zeit lang nicht klappen, auch wenn der DPM-Server aus ist,
der Dienst hängt oder die Prüfung selbst nicht mehr läuft.

- **Dead Man's Switch:** Ausbleibende Erfolgsmeldung löst den Alarm aus, nicht nur eine aktive Fehlermeldung.
- **Healthchecks.io**, ein Check pro DPM-Server, angesprochen über seine UUID-Ping-URL.
  Kein Ping-Key/Auto-Provisioning (wäre ein über alle Kunden geteiltes Geheimnis).
- **Nur ausgehendes HTTPS** aus dem Kundennetz. Kein eingehender Zugriff, kein VPN.
- **Bedienbar ohne Skript- oder Entwicklungskenntnisse:** Installation, Konfiguration, Update und Deinstallation
  über eine Oberfläche auf dem DPM-Server. Niemand muss im Alltag Code oder Konfigurationsdateien anfassen.
- **Standard: alles wird überwacht.** Ausnahmen sind explizit, mit Grund und optional befristet.
  Neu geschützte Datenquellen sind automatisch überwacht.
- **Alarmsemantik:** Regelmäßige Lücken im Zeitplan (z. B. Wochenenden bei Werktags-Plänen, wöchentliche Jobs) lösen
  keinen Alarm aus. Ein einzelner verpasster Lauf darf toleriert werden, wiederholtes Ausbleiben nicht.
- **Unbekannt ist nicht ok:** Lässt sich ein Zustand nicht ermitteln, ist das ein Fehler, kein „alles in Ordnung“.
- **Sicherheit:** Was als privilegierte geplante Aufgabe läuft, kommt aus einem Ort, den nur Admins beschreiben können.
  Keine gespeicherten Kennwörter.
- **Keine systemweiten Änderungen** am Kundenserver über das hinaus, was das Tool selbst braucht (z. B. keine TLS-Registry-Schalter).
- **Laufzeit:** nur, was auf einem DPM-Server ohnehin vorhanden ist. Keine nachzuinstallierenden Abhängigkeiten.
- **Vertraulichkeit:** Das Repository ist öffentlich. Keine Kundendaten, auch nicht in Tests, Commits oder PRs.
- Oberfläche und Meldungen auf Deutsch.

## 2. Bekannte Fakten und Fallstricke

- Die DPM-Cmdlets laufen nur in Windows PowerShell 5.1 auf dem DPM-Server.
- `LatestRecoveryPoint` & Co. werden von DPM asynchron nachgeladen; bis dahin steht dort `0001-01-01`.
  Bestehende Community-Skripte warten dafür auf `DataSourceChangedEvent`.
- `Get-DPMPolicySchedule` (ShortTerm, OffsetSchedule, LongTerm) liefert Zeitpläne pro Protection Group und Jobtyp.
  Die Eigenschaften der Rückgabeobjekte sind von Microsoft nicht dokumentiert; Struktur aus den Bestandsaufnahmen ableiten.
- Windows PowerShell 5.1 nutzt auf älteren Servern ohne Zusatzkonfiguration kein TLS 1.2.
  `SecurityProtocol` auf einen festen Wert zu setzen schließt TLS 1.3 aus.
- Eine geplante Aufgabe als SYSTEM hat keine Proxy-Einstellungen eines Benutzers. Ein Test im Admin-Kontext
  beweist nicht, dass es als SYSTEM funktioniert.
- In Unterordnern von `C:\ProgramData` dürfen normale Benutzer standardmäßig Dateien anlegen.
- Eine per Gruppenrichtlinie erzwungene Execution Policy (z. B. `AllSigned`) sticht `-ExecutionPolicy Bypass`.
- Windows PowerShell 5.1 liest `.ps1` ohne BOM als ANSI; Umlaute brechen.
- Healthchecks.io: `/fail` mit Body wird im Dashboard angezeigt. Periode und Grace Time stellt man im Dashboard ein.

## 3. Ausgangshypothesen

Aktueller Plan. Jeder Punkt darf sich bei der Implementierung als falsch herausstellen.

**Aufbau**
- PowerShell-Modul mit der Logik, ein headless Prüfskript für die geplante Aufgabe, eine WinForms-Oberfläche,
  ein `.cmd`-Starter für Doppelklick mit Rechteerhöhung, eine JSON-Config mit Schema-Version.
- „Jetzt prüfen“ in der Oberfläche nutzt exakt dieselbe Bewertungslogik wie die geplante Aufgabe.

**Bewertung**
- Datenquellen identifiziert über `ProductionServerName` + `LogicalPath`.
- Alarm nach N verpassten geplanten Terminen (N = 2), abgeleitet aus dem DPM-Zeitplan; Puffer für Jobdauer ca. 3 h.
- Rückfallebene: Stundenschwelle, global und pro Protection Group/Datenquelle überschreibbar,
  mit Voreinstellungen („täglich“, „werktags“, „wöchentlich“, „eigene“).
- Optional im Fail-Body: kritische DPM-Alerts, freier Platz im Storage Pool.

**Installation und Betrieb**
- Installationsort `C:\Program Files\DpmMonitor\`, geplante Aufgabe als SYSTEM alle 4 h.
- Nach dem Installieren die Aufgabe sofort einmal ausführen und das Ergebnis anzeigen.
- Startmenü-Verknüpfung zur Oberfläche. Update ersetzt Skripte und behält die Config.
  Deinstallation erinnert daran, den Check in Healthchecks.io zu pausieren.
- TLS 1.2 nur ergänzen, wenn nicht `SystemDefault` und TLS 1.2 fehlt. Optionales Proxy-Feld.
- Rotierendes Log im Installationsordner.

**Entwicklung**
- Pester-Tests mit synthetischen Fixtures, PSScriptAnalyzer. Dateien UTF-8 mit BOM, CRLF.

## Entscheidungslog

Neue Weggabelungen und Abweichungen von Abschnitt 3 hier eintragen: Datum, Entscheidung, Begründung, verworfene Alternativen.
Ändert sich dadurch etwas an Abschnitt 1, vorher Rücksprache.

| Datum | Entscheidung | Begründung | Alternativen |
|---|---|---|---|
| 2026-11 | Ein Healthchecks-Check pro Server über UUID-URL | Kein geteiltes Geheimnis über Kunden hinweg | Ping-Key + Slug mit Auto-Provisioning |
