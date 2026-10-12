# FHEM-HeatManager – Projektwissen

FHEM-Modul `FHEM/98_HeatManager.pm` zur Heizungsoptimierung. Zuständig: Session 7
(wie FHEM-MCP). Ziel des Nutzers: Heizkosten senken ohne Komfortverlust.

## Arbeitsweise

- **Version bei jeder funktionalen Änderung anheben** (Patch: Fix, Minor: neue
  Regel/Attribut). Stellen: Kopfzeile `# Version:`, `$HM_VERSION`. Danach
  `controls_HeatManager.txt` neu erzeugen:

  ```bash
  SIZE=$(wc -c < FHEM/98_HeatManager.pm); DATE=$(date -u +"%Y-%m-%d_%H:%M:%S")
  echo "UPD ${DATE} ${SIZE} FHEM/98_HeatManager.pm" > controls_HeatManager.txt
  ```
- Vor jedem Commit: `sh t/run.sh` (muss „ALLES GRUEN“ melden).
- Stil wie `ahlers2mi/FHEM-Pool` (PoolControl): Kopfblock mit „Funktionen:“, Autor
  ahlers2mi, Version, Lizenz; `use vars` für FHEM-Globals; jede Funktion mit
  Kasten-Kommentar (`# ----` / Name / Beschreibung / `# ----`); Zustände, die einen
  Neustart überleben müssen, in Readings (Statefile) statt nur in `$hash->{helper}`;
  Tests als `t/fhem_stub.pl` + `t/NN_*.t` + `t/run.sh`; Commandref `=begin html` mit
  `<a id="HeatManager-…">`-Ankern.
- GitHub Actions: `test.yml` (Syntax, keine github.com-URL, Funktionstests) bei Änderungen
  an `FHEM/**`/`t/**`; `update-controls.yml` erzeugt `controls_HeatManager.txt` nach jedem
  Push der .pm neu (Bot-Commit) – vor dem nächsten Push immer auf dem aktuellen `main` aufsetzen.
- Neue Regeln immer zuerst im Simulationsmodus ausliefern; scharf schalten nur
  nach Freigabe des Nutzers.
- Installation beim Nutzer: `update add https://raw.githubusercontent.com/ahlers2mi/FHEM-HeatManager/main/controls_HeatManager.txt`,
  dann `update all` und `reload 98_HeatManager` (nach jedem Update reload).
- **Nie Funktionen in den Namensraum `main` importieren** (`use JSON::PP ();`,
  `use Time::Local ();`, Aufruf voll qualifiziert). v0.4.0 hatte `use JSON::PP;` –
  das überschrieb `main::to_json`; JSON::PP::to_json stirbt absichtlich
  („has been renamed to encode_json“), 98_DoRemote.pm ruft to_json -> Main-FHEM
  stürzte am 12.10.2026 beim Update und bei jedem Neustart ab.
- Timer-Callbacks immer über `HeatManager_Safe` (eval) – ein die() im Timer beendet FHEM.
- MAX!-Funk: weekProfile sind viele Telegramme; der CUL hat ein Sendekontingent
  (1 %-Regel, „not enough credit“). Profile nur einzeln mit Minutenabstand senden.
- Keine github.com-URL in der .pm (Anon-Spiegel-Problem wie beim FHEM-MCP).
- Repo ist öffentlich: keine Tokens, Passwörter, IPs mit Zugangsdaten.

## Anlage (Stand 12.10.2026)

- SolvisMax 6, SolvisControl 2, SX 25 kW Gas. HK1 = OG (leer, Standby),
  HK2 = EG. Beide Heizkreise **ungemischt** ("Rad. ungem."), ein gemeinsamer
  Vorlauffühler S12. Steilheit HK1 1,25 / HK2 1,20.
- FHEM-Anbindung: `SolvisClient` (Gerät `mySolvis`), arbeitet per OCR/GUI-Klicks.
  Setzen dauert ~20 s (`Control` wr_ongoing → finished). Bedient jemand die
  Fernbedienung, pausiert der Server (`HumanAccess` user, ~5–8 min).
- `C15.TemperaturFeineinstellung_HK2` (−5…+5) kommt nachweislich am Regler an
  (Test 12.10.2026). `C13`/`C14` aus FHEM waren jahrelang 21/16, obwohl am Regler
  22/18 stand → diesen Readings nicht trauen.
- Thermostate: MAX! (`type=HeatingThermostat`), Raumsensoren `Mobil1data` …
  `Mobil7data`. Bestehende Standby-Logik: `n_d_ValvePositions` (Schwelle 1,6 %
  ohne Hysterese, flattert) – beim Scharfschalten von `standby` deaktivieren.
- Notfall im Bestand: `n_d_solar_check` setzt `d_solar:index` −50, wenn
  `MQTT2_Wechselrichter1:netzspannung` 0 ist; `n_d_solar_index` schaltet bei ≤ −40 alle
  großen Verbraucher ab (Klima, Garage, Wallbox, Pool …). Die Klima-Solar-Automatik
  setzt `d_clima_gaestezimmer:auto_on`.
- Konfigurationsexport der Instanzen: Repo `ahlers2mi/FHEM-Instanz` (privat),
  `Main/fhem.cfg` – zum Nachschlagen von Definitionen.
