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
- Windows PowerShell 5.1 wirft „Die Argumenttypen stimmen nicht überein“ bei `@($list)`, wenn `$list` eine
  `List[object]` ist (auch leer). Listen mit `.ToArray()` übergeben oder Arrays verwenden.
- DPM liefert viele Texte lokalisiert (`ObjectType`, `JobTypeString`, `ScheduleType`, `ScheduleDescription`,
  Datumsformat). Logik nur auf Enums, Klassennamen und Zahlen stützen, nie auf diese Texte.
- `OldestDiskRecoveryPoint` bleibt auch nach dem Nachladen `0001-01-01`, die Variante `…Time` ist gefüllt.
  Auf `0001-01-01` nur bei den tatsächlich genutzten Feldern prüfen.

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

*Welcher Zeitplan erzeugt die Wiederherstellungspunkte* (vorläufig, abgeleitet aus `LatestRecoveryPoint`;
die Liste der einzelnen Punkte fehlte wegen eines Skriptfehlers und wird mit einem zweiten Lauf nachgeholt)
- SQL: Jede Datenbank bekommt einen Punkt zur Schnellen vollständigen Sicherung. Ein Teil der Datenbanken
  (vermutlich Wiederherstellungsmodell „vollständig“) bekommt zusätzlich bei jeder Synchronisation einen Punkt;
  deren letzter Punkt lag genau auf dem Synchronisationsraster (stündlich bzw. alle 4 h).
  Verlässlicher Takt für alle SQL-Datenbanken ist damit der `FullSchedule`.
- Hyper-V: Punkt zur Schnellen vollständigen Sicherung.
- Systemschutz (Bare Metal/Systemstatus): Punkt zur Schnellen vollständigen Sicherung, auch in einer Schutzgruppe,
  die zusätzlich einen Schattenkopie-Zeitplan hat.
- Volume (Dateidaten): Punkt zur Schattenkopie-Zeit.
- Die Punkte einer Schutzgruppe entstehen nacheinander: bis ca. 60 min nach dem geplanten Start bei rund
  70 Datenquellen. Der geplante Puffer von 3 h reicht dafür.
- Bei allen Datenquellen war `LatestRecoveryPoint` = `LatestDiskRecoveryPoint`, auch mit Online- oder Bandsicherung.

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
