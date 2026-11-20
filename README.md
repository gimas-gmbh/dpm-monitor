# dpm-monitor

Überwachung von Microsoft System Center Data Protection Manager (DPM) auf On-Premises-Servern,
entwickelt von der gimas GmbH für die DPM-Server ihrer Kunden.

> **Status:** in Entwicklung. Noch nicht für den Produktivbetrieb.

## Was es tun soll

- Prüft regelmäßig auf dem DPM-Server, ob für jede geschützte Datenquelle rechtzeitig Wiederherstellungspunkte
  entstehen, abgeleitet aus den Zeitplänen der Schutzgruppen.
- Meldet das Ergebnis an [Healthchecks.io](https://healthchecks.io). Bleibt die Meldung aus, weil der Server aus ist,
  der Dienst hängt oder die Prüfung nicht mehr läuft, schlägt Healthchecks.io Alarm (Dead Man's Switch).
- Nur ausgehendes HTTPS, keine Laufzeitabhängigkeiten außer Windows PowerShell 5.1 und dem DPM-Modul.
- Installation, Konfiguration, Update und Deinstallation über eine Oberfläche auf dem DPM-Server.

Details, Ziele und Entscheidungen: [DESIGN.md](DESIGN.md).

## Bestandsaufnahme

[`tools/Get-DpmInventory.ps1`](tools/Get-DpmInventory.ps1) liest Schutzgruppen, Datenquellen, Zeitpläne,
Wiederherstellungspunkte, Alerts sowie Proxy- und TLS-Einstellungen eines DPM-Servers aus. Es ändert nichts.

1. Skript auf den DPM-Server kopieren.
2. Rechtsklick → „Mit PowerShell ausführen“. Das Skript fordert bei Bedarf Administratorrechte an.
3. Ergebnis ist eine ZIP-Datei auf dem Desktop.

Die ZIP enthält Server-, Domänen- und Datenquellennamen des Kunden. Sie gehört nicht in dieses Repository.

## Entwicklung

- Zielplattform: Windows PowerShell 5.1 auf dem DPM-Server.
- `src/DpmMonitor.psm1` enthält die Logik, `src/Check.ps1` ist das Prüfskript für die geplante Aufgabe.
- Tests mit [Pester](https://pester.dev) 5, statische Analyse mit PSScriptAnalyzer (nur für die Entwicklung nötig):

  ```powershell
  Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -SkipPublisherCheck
  Install-Module PSScriptAnalyzer -Scope CurrentUser
  powershell.exe -NoProfile -File tools\Invoke-Tests.ps1
  ```

- Dateien UTF-8 mit BOM, CRLF (siehe `.gitattributes`). `tools\Format-SourceFiles.ps1` korrigiert das,
  ein Test prüft es.
- Hinweise für Mitwirkende und Agents: [AGENTS.md](AGENTS.md).
