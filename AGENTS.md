# Hinweise für Agents

Lies zuerst [DESIGN.md](DESIGN.md) (Ziele, bekannte Fakten, Ausgangshypothesen, Entscheidungslog).

## Vertraulichkeit

Das Repository ist öffentlich. Individuelle Namen aus Kunden- oder internen Umgebungen werden nie committet:
Server-, Domänen-, Konto-, Kunden-, Protection-Group-, Datenquellen-, Datenbank- und VM-Namen,
dazu auffällige Pfade und IDs. Das gilt für Code, Tests, Fixtures, Doku, Kommentare, Commit-Messages,
Branch-Namen sowie PR- und Issue-Texte.

- Bestandsaufnahmen (Ausgabe von `tools/Get-DpmInventory.ps1`) nur nutzen, um Strukturen zu verstehen.
  Nie ins Repo-Verzeichnis kopieren, auch nicht in ignorierte Ordner.
- Fixtures und Beispiele sind synthetisch, mit erfundenen Namen (z. B. `SRV-APP01`, `example.local`, `PG Fileserver`).
- Allgemeine Produkt- und Systembezeichnungen (z. B. `master`, `msdb`, `Host Component`, `System Protection`) sind unkritisch.

**Vor jedem Push und jeder Veröffentlichung** (PR, Issue, Release) prüft ein Subagent auf dem günstigsten
verfügbaren Modell den zu veröffentlichenden Stand: Diff gegenüber dem Remote, Commit-Messages, Branch-Name,
PR-/Issue-Text. Er meldet alles, was nach internen, nicht allgemeinen Namen aussieht. Funde werden vor der
Veröffentlichung entfernt; solange nicht gepusht ist, auch aus der History.

## Konventionen

- Laufzeit: Windows PowerShell 5.1, keine Laufzeitabhängigkeiten. Pester und PSScriptAnalyzer nur für die Entwicklung.
- Dateien UTF-8 mit BOM, CRLF (`.gitattributes`).
- Oberfläche und Meldungen auf Deutsch, Code und Bezeichner auf Englisch.
- Kleine, nachvollziehbare Commits.
