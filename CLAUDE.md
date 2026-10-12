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
- Vor jedem Commit: `perl t/test_heatmanager.pl` (muss 0 Fehler melden).
- Neue Regeln immer zuerst im Simulationsmodus ausliefern; scharf schalten nur
  nach Freigabe des Nutzers.
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
