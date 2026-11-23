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
  Unaufgelöste DPM-Alerts der Stufe „Error“ gelten als Fehler, wenn sie länger als eine Schwelle offen sind
  (Vorschlag 24 h); Ausnahmen gelten auch für sie. Umsetzung nach den Daten aus dem Pilot.
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
  Bestätigt (2026-11-20, Test-Check): Erfolg und `/fail` per POST liefern HTTP 200, auch aus der geplanten Aufgabe
  als SYSTEM. Die Ereignisliste zeigt kurze Bodies direkt, längere nur als „N byte body“ (voller Text per Klick).
  Eine unbekannte UUID beantwortet hc-ping.com mit HTTP 400.
- Windows PowerShell 5.1 wirft „Die Argumenttypen stimmen nicht überein“ bei `@($list)`, wenn `$list` eine
  `List[object]` ist (auch leer). Listen mit `.ToArray()` übergeben oder Arrays verwenden.
- DPM liefert viele Texte lokalisiert (`ObjectType`, `JobTypeString`, `ScheduleType`, `ScheduleDescription`,
  Datumsformat). Logik nur auf Enums, Klassennamen und Zahlen stützen, nie auf diese Texte.
- `OldestDiskRecoveryPoint` bleibt auch nach dem Nachladen `0001-01-01`, die Variante `…Time` ist gefüllt.
  Auf `0001-01-01` nur bei den tatsächlich genutzten Feldern prüfen.
- In Windows PowerShell 5.1 ist `$PSScriptRoot` in Standardwerten des `param()`-Blocks leer.
  Pfade relativ zum Skript erst im Skriptrumpf bilden.
- PowerShell behandelt typografische Anführungszeichen (`„` `“` `”`) wie `"`. In Zeichenketten mit `"…"`
  brechen sie das Parsen; deutsche Anführungszeichen nur in `'…'` verwenden.
- `cmd.exe` stolpert über ein BOM in der ersten Zeile. `.cmd`-Dateien bleiben reines ASCII ohne BOM.
- WinForms-Ereignisse laufen im Scope des Aufrufers von `ShowDialog()`. Fenster daher in derselben Funktion
  aufbauen und anzeigen, sonst sehen die Handler deren Variablen nicht.
- Dateien aus einer heruntergeladenen ZIP tragen die Internet-Zonenmarkierung; bei `RemoteSigned` per
  Gruppenrichtlinie laufen sie erst nach `Unblock-File`. Ein Doppelklick auf eine markierte `.cmd` zeigt
  die Windows-Sicherheitswarnung („Herausgeber konnte nicht verifiziert werden“); `Start-Process` wartet
  dabei, bis jemand sie beantwortet.
- Windows PowerShell ist nicht DPI-aware: auf 4K-Bildschirmen streckt Windows WinForms-Fenster als Bitmap,
  die Schrift wird unscharf. Abhilfe: `SetProcessDPIAware()` vor dem ersten Fenster und Pixelmaße mit
  dem DPI-Faktor skalieren (Schriften in Punkt skalieren selbst).
- In der Windows Sandbox lässt sich `Microsoft.PowerShell.Archive` (`Expand-Archive`) nicht laden.
- `Add-Type` mit C#-Quelltext (auch `-MemberDefinition`) startet in Windows PowerShell 5.1 bei jedem Aufruf den
  C#-Compiler; das kostet auf Servern Sekunden. Für einzelne P/Invokes `Reflection.Emit` nutzen.
- Windows PowerShell 5.1 macht Stderr nativer Programme bei `2>&1` zu Fehlerobjekten; mit
  `$ErrorActionPreference = 'Stop'` bricht das ab. Und `powershell.exe -File` ohne `exit` kann den
  `$LASTEXITCODE` eines Kindprozesses als eigenen Exit-Code liefern. Skripte enden daher mit explizitem `exit`.

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

**Erkenntnisse aus den Bestandsaufnahmen** (2 Server, DPM 2019 und DPM 2022 auf Windows Server 2019,
deutsche Oberfläche, 26 bzw. 139 Datenquellen, 2 bzw. 3 Schutzgruppen; Stand 2026-11)

*Struktur von `Get-DPMPolicySchedule`*
- `-ShortTerm` liefert je Schutzgruppe eine Liste von Objekten verschiedener Klassen:
  - `ReplicationSchedule`: `Frequency` in Minuten (gesehen: 60, 240), `JobType` = `Replication`.
    Fehlt bei Schutzgruppen, die nur vor einem Wiederherstellungspunkt synchronisieren.
  - `ShadowCopySchedule`: `TimesOfDay` (Liste von `DateTime`), `WeekDays` (Liste), `SCOffset` (Minuten),
    `JobType` = `ShadowCopy`. `TimesOfDay` enthält den Offset bereits (Beschreibung „18:00“, `TimesOfDay` 18:04,
    `SCOffset` 4). Nur bei Schutzgruppen mit Dateidaten gesehen.
  - `FullSchedule` (Schnelle vollständige Sicherung): `TimesOfDay`, `WeekDays`, `JobType` = `FullReplicationForApplication`.
- In `TimesOfDay` zählt nur die Uhrzeit; das Datum ist der Abfragetag.
- `WeekDays` ist eine Liste von Flags: So = 1, Mo = 2, Di = 4, Mi = 8, Do = 16, Fr = 32, Sa = 64
  (live als Enum-Namen `Su`, `Mo`, …; nach CLIXML-Export als Zahlen). In beiden Aufnahmen sind alle Pläne täglich,
  Werktags-Pläne kamen nicht vor.
- `-OffsetSchedule` liefert nur eine Zahl (überall 0).
- `-LongTerm Online` liefert `CloudBackupSchedule` (`TimesOfDay`, `WeekDays`, `Interval`, `Frequency`, `MonthDays`,
  `RelativeIntervals`, `RelativeWeekDays`, `Months`), gesehen wöchentlich freitags.
  `-LongTerm Tape` liefert `ArchiveSchedule` (`Frequency`, `Interval`, `WeekDay(s)`, `RelativeWeekDay`,
  `RelativeInterval`, `ScheduleTime` mit Datum als Anker, `Generation`, `Vault`), gesehen monatlich am 1.

*Welcher Zeitplan erzeugt die Wiederherstellungspunkte* (zuerst abgeleitet aus `LatestRecoveryPoint`, am
2026-11-23 auf dem Server mit 139 Datenquellen mit der Liste der einzelnen Punkte bestätigt)
- SQL: Jede Datenbank bekommt einen Punkt zur Schnellen vollständigen Sicherung. Ein Teil der Datenbanken
  (vermutlich Wiederherstellungsmodell „vollständig“, 72 von 109 gültigen) bekommt zusätzlich bei jeder
  Synchronisation einen Punkt, genau auf dem Synchronisationsraster (stündlich bzw. alle 4 h).
  Verlässlicher Takt für alle SQL-Datenbanken ist damit der `FullSchedule`: Jede gültige Datenquelle hatte im
  erfassten Zeitraum an jedem Tag einen solchen Punkt, ohne Lücke.
- Unterscheidbar am Punkt selbst: `IsIncremental` = `False` bei der Schnellen vollständigen Sicherung,
  `True` bei Synchronisationspunkten.
- Hyper-V: Punkt zur Schnellen vollständigen Sicherung.
- Systemschutz (Bare Metal/Systemstatus): Punkt zur Schnellen vollständigen Sicherung, auch in einer Schutzgruppe,
  die zusätzlich einen Schattenkopie-Zeitplan hat.
- Volume (Dateidaten): Punkt zur Schattenkopie-Zeit.
- Die Punkte einer Schutzgruppe entstehen nacheinander: bis ca. 60 min nach dem geplanten Start bei rund
  70 Datenquellen; bei rund 110 Datenquellen meist 60–80 min, in 30 Tagen höchstens gut 2 h.
  Der geplante Puffer von 3 h reicht dafür.
- `LatestRecoveryPoint` ist der neueste Disk-Punkt, nie ein Bandpunkt (Bandpunkte sind Kopien älterer
  Disk-Punkte). Im ersten Lauf war `LatestDiskRecoveryPoint` gleich, im zweiten überall `0001-01-01`
  (ebenso `TotalDiskRecoveryPoints` = 0). Die `…Disk…`-Felder sind also unzuverlässig; die Prüfung nutzt sie nicht.

*Wiederherstellungspunkte im Detail* (`Get-DPMRecoveryPoint`, DPM 2022)
- Speicherort in `Location`/`DataLocation`: `Disk` oder `Media` (Band). Online-Punkte kamen nicht vor:
  keine Schutzgruppe mit Online-Zeitplan (`-LongTerm Online` leer), `-Online` lieferte nichts.
- Bandpunkte entstehen hier monatlich am 1. (monatlicher Band-Zeitplan am 1. um 23:00). Ihr
  `RepresentedPointInTime` ist der Zeitpunkt des kopierten Disk-Punkts, also vor der Bandsicherung.
  Ohne aktuellen Bandpunkt waren genau die 13 inkonsistenten, seit Langem nicht mehr gesicherten Datenquellen.
- `RPExpirtyTime` (sic) ist immer `0001-01-01`, `RetentionType` leer.
- Laufzeit: 139 Datenquellen mit je einem Aufruf ohne und einem mit `-Online` brauchten knapp 3 h (rund 75 s pro
  Datenquelle). Für die Prüfung alle 4 h ist `Get-DPMRecoveryPoint` damit zu langsam; eine Bandüberwachung
  muss anders oder seltener prüfen. Wie sich die Zeit auf die beiden Aufrufe verteilt, zeigt der nächste Lauf
  (`43_recoverypoints_abrufdauer.csv`).

*Alerts* (zweiter Server, Stand 2026-11-23)
- Offen waren zwei `ShadowCopyFailedAlert` der Stufe Error (unter 1 h offen) und zwei Warnungen
  (Bandvorrat seit über 260 Tagen, Katalog seit 5 Tagen). Warnungen bleiben also lange offen; nur Error-Alerts
  mit Schwelle zu zählen passt dazu.

*Asynchrones Nachladen*
- Das Warten auf `DataSourceChangedEvent` funktioniert: keine `0001-01-01` in `LatestRecoveryPoint` und
  `OldestRecoveryPoint`, alle Events kamen nach 0,6 bzw. 1,1 s.

*Netzwerk*
- Beide Server: `SecurityProtocol` ab Werk `Tls, Tls11, Tls12` (nicht `SystemDefault`, TLS 1.2 vorhanden),
  `https://hc-ping.com/` antwortet mit HTTP 200, WinHTTP-Proxy „direkt“. Es ist also keine TLS-Anpassung nötig.
- Getestet wurde als Administrator. `Invoke-WebRequest` nutzt die Proxy-Einstellungen des Benutzers, nicht WinHTTP.
  Ob es als SYSTEM klappt, zeigt erst der erste Lauf der geplanten Aufgabe.

*Datenquellen-Zustände*
- Klassenname in `Type` (z. B. `SQLObjectType`, `HyperVRctObjectType`, `HyperVObjectType` für die Host-Komponente,
  `FsObjectType`, `SystemProtectionObjectType`) ist sprachunabhängig; `ObjectType` ist lokalisiert.
- Ein Server hatte 13 SQL-Datenbanken mit `State` = `Invalid` und letztem Punkt vor Wochen bis Monaten,
  alle mit `CurrentProtectionState` = `Protected`. Die erste Prüfung nach der Installation wird bei solchen
  Servern sofort Alarm schlagen. Die Oberfläche muss diese Datenquellen bei der Einrichtung deutlich zeigen
  und Ausnahmen anbieten.
- `CurrentlyProtected` = `False` (`CurrentProtectionState` = `UserInputPending`) kam bei Datenquellen mit
  aktuellen Punkten vor. Dieses Feld taugt nicht, um Datenquellen von der Prüfung auszunehmen.

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
| 2026-11-20 | Schutz vor Leaks durch eine Regel in AGENTS.md: vor jeder Veröffentlichung prüft ein günstiger Subagent | Wenig Aufwand, keine Einrichtung pro Rechner | Git-Hooks mit lokaler Sperrliste (zu viel Aufwand) |
| 2026-11-20 | Keine Lizenzdatei | Repo ist öffentlich aus praktischen Gründen, kein klassisches OSS-Projekt | MIT, proprietärer Lizenztext |
| 2026-11-20 | Datenquellentyp über den Klassennamen in `Type`, nicht über `ObjectType` | `ObjectType` ist lokalisiert | Texte je Sprache abgleichen |
| 2026-11-20 | Erwarteter Takt (vorläufig): `FullSchedule` für SQL, Hyper-V und Systemschutz; `ShadowCopySchedule` für Dateidaten; Synchronisation zählt nicht als Takt | Sync-Punkte entstehen nur für einen Teil der SQL-Datenbanken; bestätigen mit der Liste der Punkte aus dem zweiten Lauf | Kürzesten Plan der Schutzgruppe nehmen (würde bei SQL im einfachen Modell falsch alarmieren) |
| 2026-11-20 | Verpasste Termine = geplante Termine nach (letzter Punkt + 15 min) bis (jetzt − Puffer). Ab N Terminen „Fehler“, darunter „Warnung“ im Bericht, aber Erfolgsmeldung | Zählt in Ortszeit, damit Zeitumstellung, Wochenenden und Werktags-Pläne ohne Sonderfälle stimmen. Die 15 min decken Punkte, die vor der geplanten Zeit gestempelt sind (Schattenkopie 18:04, Punkt 18:00) | Alter in Stunden gegen Intervall (bricht bei Werktags-Plänen und Zeitumstellung) |
| 2026-11-20 | Termine in der Lücke der Sommerzeit-Umstellung zählen eine Stunde später, Termine in der doppelten Stunde einmal | Deterministisch; das genaue DPM-Verhalten ist unbekannt und für N = 2 unerheblich | Termin auslassen |
| 2026-11-20 | Ohne Wiederherstellungspunkt oder ohne ermittelbaren Zeitplan: Fehler. `FallbackMaxAgeHours` greift nur, wenn er gesetzt ist (Standard: leer) | „Unbekannt ist nicht ok“ | Standard-Stundenschwelle (würde fehlende Zeitpläne verdecken) |
| 2026-11-20 | Abweichende Regeln: pro Schutzgruppe oder Datenquelle entweder `MaxAgeHours` oder eigene Wochentage/Uhrzeiten; Datenquellen-Regel schlägt Schutzgruppen-Regel. Die Voreinstellungen der Oberfläche („täglich“, „werktags“, „wöchentlich“) werden auf Wochentage/Uhrzeiten abgebildet | Ein Modell für alle Fälle; „werktags“ ist mit einer Stundenschwelle nicht darstellbar | Getrennte Felder je Voreinstellung |
| 2026-11-20 | Ausnahmen gelten bis einschließlich `Until` (Ortszeit). Abgelaufene oder ins Leere zeigende Ausnahmen und Regeln erscheinen als Hinweis im Bericht, ohne Fehler auszulösen | Admin sieht, was wieder überwacht wird, ohne Fehlalarm | Abgelaufene Ausnahmen als Fehler |
| 2026-11-20 | Prüfung liefert Exit-Codes 0 ok, 1 Sicherung/Prüfung fehlgeschlagen, 2 Konfiguration unbrauchbar (kein Ping möglich), 3 Ping nicht zugestellt | Geplante Aufgabe und „Jetzt prüfen“ können den Fall unterscheiden; Healthchecks.io alarmiert in 2 und 3 über das Ausbleiben | Nur 0/1 |
| 2026-11-20 | Layout `src/` (Modul, Prüfskript), `tests/` (Pester 5, synthetische Fixtures, DPM-Cmdlets als Stubs gemockt), `tools/` (Bestandsaufnahme, Testlauf, Kodierung). PSScriptAnalyzer prüft `src/` und `tools/` | Tests mit Pester-Scopes erzeugen Fehlalarme im Analyzer | Analyzer auch für Tests mit vielen Unterdrückungen |
| 2026-11-20 | „Jetzt prüfen“ startet die geplante Aufgabe (SYSTEM, inklusive Ping) und zeigt deren Ergebnis aus `last-result.json`. Die Liste der Datenquellen in der Oberfläche bewertet dagegen im Admin-Kontext ohne Ping, auch mit ungespeicherten Änderungen | Nur der echte Lauf als SYSTEM beweist Proxy, TLS und Ausführungsrichtlinie (siehe Fakten). Die Vorschau gibt beim Konfigurieren sofort Rückmeldung | Prüfung im Admin-Kontext mit Ping |
| 2026-11-20 | `config.json` nur für Administratoren und SYSTEM lesbar | Wer die Ping-URL kennt, kann für den Server „ok“ melden | Standardrechte von Program Files (für alle Benutzer lesbar) |
| 2026-11-20 | Geplante Aufgabe: erster Start zur nächsten vollen Stunde, dann alle 4 h; verpasste Starts nachholen, höchstens 1 h Laufzeit, keine parallelen Läufe | Wiederanlauf nach Neustart, keine hängenden Läufe | Start beim Systemstart zusätzlich |
| 2026-11-20 | Update über dasselbe Paket: neuere Version ersetzt die Skripte und behält `config.json`; gleiche Version nur nach Rückfrage, ältere nie. Deinstallation entfernt Aufgabe, Verknüpfung, Skripte, Konfiguration und Protokoll, fremde Dateien bleiben | Ein Ablauf für Neuinstallation und Update | Getrenntes Update-Skript |
| 2026-11-20 | Release über GitHub Actions: Tests und Testbuild bei jedem Push/PR auf `windows-latest` mit Windows PowerShell 5.1; bei Tag `v*` Paket bauen und Release mit ZIP und SHA-256 anlegen. Einzige Fremd-Action ist `actions/checkout`, per Commit-SHA gepinnt; das Release legt das vorinstallierte `gh` an. Version steht nur im Modul, der Tag muss passen | Öffentliches Repo, daher kostenlos; reproduzierbar und unabhängig vom Entwicklerrechner. Wenige, gepinnte Abhängigkeiten in der Lieferkette | Lokales Build-Skript allein; Release-Actions von Drittanbietern |
| 2026-11-20 | ZIP-Einträge einzeln mit `/` anlegen | `ZipFile.CreateFromDirectory` in .NET Framework kann Backslashes schreiben, die das ZIP-Format nicht erlaubt | `Compress-Archive` (gleiches Problem in PowerShell 5.1) |
| 2026-11-20 | Versionierung mit Nerdbank.GitVersioning (nbgv, als lokales dotnet-Tool gepinnt): `version.json` hält Major.Minor, die Git-Höhe liefert die dritte Stelle. Der Build stempelt Version und Commit in die `DpmMonitor.psm1` des Pakets, im Quelltext steht `0.0.0-dev`. Jeder CI-Lauf legt das Paket als Artefakt ab; Releases über `nbgv tag` und Tag-Push. Ersetzt „Version steht nur im Modul“ | Jeder Stand hat eine eindeutige, steigende Version, die die Update-Logik versteht; Testpakete für DPM-Server ohne Release. Kein manuelles Hochzählen, Commit im Bericht nachvollziehbar | Version von Hand im Modul pflegen |
| 2026-11-20 | Produktname in der Oberfläche und im Startmenü „gimas DPM Monitor“, Icon `DpmMonitor.ico` (gimas-Logo) für Fenster und Verknüpfung. Repository, Installationsordner und Aufgabe heißen weiter `dpm-monitor`/`DpmMonitor`; der Bericht an Healthchecks.io beginnt weiter mit „DPM-Überwachung <Server>“ | Wunsch nach gimas-Branding in der Oberfläche; technische Namen bleiben stabil | – |
| 2026-11-20 | Oberfläche DPI-aware (System-DPI) mit explizit skalierten Pixelmaßen | Scharf auf 4K-Bildschirmen; Per-Monitor-DPI bräuchte eine App-Konfiguration, die `powershell.exe` nicht hat | `AutoScaleMode` von WinForms (skaliert nicht alle Maße, z. B. Spaltenbreiten) |
| 2026-11-20 | Ende-zu-Ende-Test in Windows Sandbox (`tools\Test-InSandbox.ps1`): Installation aus markiertem Paket, Aufgabe als SYSTEM gegen ein Fake-DPM-Modul, Update, Oberfläche, Deinstallation | Prüft, was Unit-Tests nicht können (Aufgabenplanung, Rechte, Zonenmarkierung, SYSTEM-Kontext, Netz) | Test auf dem Entwicklerrechner (verändert das System) |
| 2026-11-20 | Windows-Sicherheitswarnung beim Start aus heruntergeladener ZIP vorerst nur dokumentieren | Kostenlos; Code-Signing würde Warnung und `AllSigned` lösen, kostet aber ein Zertifikat und Pflege – Entscheidung offen | Code-Signing |
| 2026-11-20 | Bis zum Pilot auf einem echten DPM-Server bleibt die Version 0.x; 1.0 nach ein, zwei Wochen Pilot ohne Fehlalarm | Lauf gegen echte DPM-Objekte und der Takt je Datenquellentyp sind noch unbestätigt | Sofort 1.0 |
| 2026-11-20 | Bestandsaufnahme für den Pilot erweitert: Recovery Points je Speicherort (Disk/Band/online, je Gruppe die neuesten 30, dazu eine Übersicht), Speicher (`Get-DPMDiskStorage`), Alerts strukturiert mit Offen-Dauer | Grundlage für Langzeit- und Speicherüberwachung und für die Frage, ob unaufgelöste Error-Alerts als Fehler zählen sollen (Vorschlag: ab 24 h offen, Ausnahmen gelten) | Diese Überwachungen ohne Daten bauen |
| 2026-11-20 | Unaufgelöste Error-Alerts zählen als Fehler, wenn sie länger als eine Schwelle offen sind; Ausnahmen gelten auch für sie (Abschnitt 1 nach Rücksprache ergänzt). Schwelle und Umsetzung nach den Pilot-Daten | Dauerprobleme früher sehen, ohne einzelne Ausrutscher zu melden; die typische Offen-Dauer ist noch unbekannt | Jeder Error-Alert sofort als Fehler (widerspricht „einzelner Ausrutscher wird toleriert“); Alerts nur im Bericht |
| 2026-11-23 | Ausnahmen und abweichende Regeln auch für einen Server innerhalb einer Schutzgruppe (`ProtectionGroup` + `ProductionServerName`, ohne Pfad). Vorrang bei Regeln: Datenquelle vor Server vor Schutzgruppe. Die Oberfläche erlaubt Mehrfachauswahl und legt je Ziel einen Eintrag an (gleicher Grund, gleiches Ablaufdatum). Bei mehreren aktiven Ausnahmen liefert die spezifischste den Grund; eine abgelaufene Ausnahme erscheint nur als Hinweis, wenn keine andere aktive die Datenquelle noch ausnimmt; Regeln für ausgenommene Datenquellen gelten nicht als „passt zu keiner Datenquelle“ | Zwischenebene, wenn ein Server abgelöst wird oder mehrere Datenquellen eines Servers denselben Grund haben; Mehrfachauswahl spart Klicks bei vielen Datenquellen. Schema bleibt 1, ältere Versionen würden solche Einträge ablehnen, ein Downgrade ist aber ohnehin ausgeschlossen | Server über alle Schutzgruppen (unklarer Bezug); ein Eintrag mit Liste von Zielen (komplizierteres Schema, Entfernen einzelner Ziele schwerer) |
| 2026-11-23 | Bestandsaufnahme: Recovery Points zuletzt lesen, `-Online` nur bei Schutzgruppen mit Online-Zeitplan (oder unbekanntem), Dauer je Datenquelle protokollieren, Teilergebnis bei Abbruch speichern, Schalter `-SkipRecoveryPoints` | Der Schritt dauerte bei 139 Datenquellen sehr lange; die Dauer pro Aufruf zeigt außerdem, ob `Get-DPMRecoveryPoint` für eine spätere Langzeitüberwachung schnell genug ist | Nur eine Stichprobe von Datenquellen lesen (verliert seltene Band-/Online-Punkte) |
| 2026-11-23 | Oberfläche startet schneller: Neustart mit Administratorrechten vor dem Laden von Modul und WinForms, P/Invoke für DPI ohne C#-Compiler, DPM wird in einem Hintergrund-Runspace gelesen (einer pro Fenster, STA, derselbe Thread für jedes Neuladen) und per Timer übernommen; die Dauer steht in der Zusammenfassung | Start über die Verknüpfung lud alles doppelt; DPM-Modul und Verbindung kosten Sekunden, das Fenster war so lange gesperrt. Kann der Runspace nicht gestartet werden, liest die Oberfläche wie bisher im Vordergrund | Parallele Abfragen je Schutzgruppe (gleiche DPM-Verbindung, kaum Gewinn, mehr Komplexität) |
