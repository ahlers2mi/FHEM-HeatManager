# FHEM-HeatManager

FHEM-Modul zur Heizungsoptimierung: **weniger Gas, ohne Komfort zu verlieren.**

Ausgangslage (Anlage des Autors): SolvisMax 6 (Gas, SolvisControl 2, über
`SolvisClient`/SolvisSmartHomeServer angebunden), Heizkörper mit MAX!-Thermostaten,
Raumsensoren, PV-Inselanlage, Klimagerät, Kachelofen.

## Regeln

| Regel | Status | Was sie tut |
|---|---|---|
| `curve` | v0.1.0 | Einmal täglich (Default 05:00): Ventile der letzten 24 h im Mittel unter 10 % und kein Raum zu kalt → Feineinstellung −1. Ein Raum über 60 min mehr als 0,5 K unter Soll oder ein Ventil im Mittel über 60 % → +1. Grenzen −3 … +2. Aufheizphasen nach Sollwertsprüngen (90 min) werden ausgeblendet. Nach dem Setzen wird geprüft, ob der Wert am Regler angekommen ist (SolvisClient pausiert bei `HumanAccess`). |
| `standby` | v0.1.0 | Heizkreis in Standby, wenn das Ventilmittel unter 1,5 % fällt; zurück in Timer erst über 3 %; mindestens 30 min je Zustand. |
| `klima` | v0.2.0 | Steht das Ventil von `hmClimaRoom` (Wohnzimmer) 60 min im Mittel über 50 %, heizt das Klimagerät mit – über `autoTemperature` des Automatik-Dummys, also nur wenn dieser auf `auto` steht. Bedingungen: Zeitfenster (07:00–20:30, Nachbarin), Freigabe der Klima-Heizgrenze, Akku ≥ 60 % (oder `hmClimaGrid 1` und außen ≥ 3 °C), max. 2 Starts/Tag, je mind. 60 min Lauf und Pause. Aus, wenn der Raum 0,5 K über Soll ist, das Zeitfenster endet oder der Akku 10 % unter die Schwelle fällt. Übernimmt der Nutzer (Modus `manuel`), hält sich das Modul raus. **Notfall:** liegt am Wechselrichter kein Netz an (`hmGridSensor`, < 100 V), startet die Klima nie und ein laufender Lauf endet sofort (ab v0.2.1). |
| `ofen` | v0.2.0 | Stahleinsatz > 60 °C → „brennt“, Kacheln > 35 °C → „speichert“ (2 K Hysterese). Dann Wohnzimmer, Gästezimmer, Bad Altbau auf 17 °C; vorher `auto` oder Wert wird gemerkt und danach wiederhergestellt – aber nur, wenn noch 17 °C eingestellt sind (Nutzeränderungen bleiben). |
| Prognose / Sonne | geplant | PV- und Wetterprognose (SolarForecast) für Morgenkorrektur und Klima. |
| Saison | geplant | Heizbeginn/-ende: Thermostate auto ↔ manual/off. |

## Installation

```
update add https://raw.githubusercontent.com/ahlers2mi/FHEM-HeatManager/main/controls_HeatManager.txt
update all
reload 98_HeatManager
define heizung HeatManager
attr heizung hmRoomSensors MAX_040549:Mobil5data MAX_0404d9:Mobil1data MAX_06e2ff:Mobil6data
attr heizung hmIgnore MAX_0423d1
```

Durch `update add` ist das Repo bei jedem künftigen `update all` dabei; nach einem
Update jeweils `reload 98_HeatManager`.

Das Modul startet im **Simulationsmodus** (`hmSimulate 1`): es sammelt Messwerte,
rechnet und schreibt, was es tun würde (`sim_curve`, `sim_standby`,
`last_action`), schaltet aber nichts. Scharf schalten mit `attr heizung hmSimulate 0`.

**Achtung beim Scharfschalten der Regel `standby`:** eine bestehende eigene
Standby-Logik (z. B. ein notify auf die Ventilstellungen) vorher deaktivieren,
sonst schalten zwei Logiken gegeneinander.

## Bedienung

- `set heizung evaluate` – Auswertung jetzt (im Simulationsmodus ohne Wirkung)
- `set heizung clearSamples` – Messwerte verwerfen
- `get heizung status` – aktuelle Auswertung als Text

Wichtige Readings: `valve_avg_now`, `valve_avg_24h`, `valve_max_room`,
`cold_room`, `samples_24h`, `fine_current`, `fine_target`, `decision`,
`standby_target`, `standby_info`, `verify`, `last_action`.

## Attribute

Siehe Commandref im Modul (`help HeatManager`). Die wichtigsten:
`hmSimulate`, `hmRules`, `hmThermostats`, `hmIgnore`, `hmRoomSensors`,
`hmHeater`, `hmFineReading`, `hmModeReading`, `hmFineMin`/`hmFineMax`,
`hmCheckTime`, `hmValveLow`/`hmValveHigh`, `hmColdDelta`/`hmColdMinutes`,
`hmRampIgnore`, `hmStandbyLow`/`hmStandbyHigh`/`hmStandbyMinTime`, `hmNotifyCmd`.

Hinweis: Messwerte liegen nur im Speicher. Nach einem FHEM-Neustart sammelt das
Modul neu; die nächste Auswertung wartet, bis mindestens 50 % eines Tages
vorliegen (`hmMinSamplesPct`).

## Test

```
perl t/test_heatmanager.pl
```

Läuft ohne FHEM (Stubs für die FHEM-API) und prüft Heizkurve, Standby-Hysterese,
Ofen und Klima (40 Fälle).

Räume, die gerade von Ofen oder Klima beeinflusst werden, zählen nicht für die
Heizkurve (Reading `excluded_rooms`) – sonst würde die Kurve wegen der künstlich
geschlossenen Ventile zu weit sinken.
