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
| `klima` | v0.2.0 | Steht das Ventil von `hmClimaRoom` (Wohnzimmer) 60 min im Mittel über 50 %, heizt das Klimagerät mit – über `autoTemperature` des Automatik-Dummys, also nur wenn dieser auf `auto` steht. Bedingungen: Zeitfenster (07:00–20:30, Nachbarin), Freigabe der Klima-Heizgrenze, Akku ≥ 60 % (oder `hmClimaGrid 1` und außen ≥ 3 °C), max. 2 Starts/Tag, je mind. 60 min Lauf und Pause. Aus, wenn der Raum 0,5 K über Soll ist, das Zeitfenster endet oder der Akku 10 % unter die Schwelle fällt. Übernimmt der Nutzer (Modus `manuel`), hält sich das Modul raus. Läuft die vorhandene Solar-Automatik (`auto_on`), hält sich das Modul raus. **Notfall** (kein Netz: `netzspannung` < 100 V oder `d_solar:index` ≤ −40 wie in `n_d_solar_index`): die Klima startet nie, ein laufender Lauf endet sofort. |
| `ofen` | v0.2.0 | Stahleinsatz > 60 °C → „brennt“, Kacheln > 35 °C → „speichert“ (2 K Hysterese). Dann Wohnzimmer, Gästezimmer, Bad Altbau auf 17 °C; vorher `auto` oder Wert wird gemerkt und danach wiederhergestellt – aber nur, wenn noch 17 °C eingestellt sind (Nutzeränderungen bleiben). |
| `sonne` | v0.4.0 | Ab 06:00 Tagesplan: ist für 09–15 Uhr laut `Forecast` (SolarForecast, `Today_HourHH_PVforecast`) mindestens 8 kWh PV angesagt und mittags (`rem_DWD:fc0_12_TTT`) mindestens 3 °C, wird die Feineinstellung im Fenster um eine Stufe gesenkt und danach auf den Ausgangswert zurückgestellt. |
| `saison` | v0.4.0 | Täglich mit der Auswertung: liegt das Tagesmittel der DWD-Prognose (`fc0_Tx`/`fc0_Tn`) 3 Tage in Folge unter 12 °C → alle Thermostate auf `auto` (Wochenplan); 3 Tage über 16 °C → auf `off` (wie im Sommer von Hand, schont die Batterien). Schaltet mit 20 s Abstand. |
| `rampe` | v0.8.0 | Zwischenwert `hmRampMinutes` (30) vor einem Profilsprung nach oben ≥ `hmRampMinDelta` (1,5 K): `desiredTemperature auto <Mittel>`, ein Funkbefehl, Thermostat bleibt auf `auto`. Siehe „Neu in v0.8.0“. |
| `tag` | v0.9.0 | Nachregelung tagsüber: stündlich 07–21 Uhr; Ventile seit 120 min überwiegend über 50 % offen und mindestens 2 Räume 0,8 K unter Soll → Feineinstellung +1, höchstens 2 Stufen pro Tag, nur nach oben. Startet simuliert (`hmSimOnly`). Siehe „Neu in v0.9.0“. |

## Installation

```
update add https://raw.githubusercontent.com/ahlers2mi/FHEM-HeatManager/main/controls_HeatManager.txt
update all
reload 98_HeatManager
define heizung HeatManager
attr heizung hmRoomSensors MAX_040549:Mobil5data MAX_0404d9:Mobil1data MAX_06e31a:Mobil6data
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

### Neu in v0.9.0

- **Regel `tag` (Nachregelung tagsüber):** Die Heizkurve wird sonst nur einmal
  täglich (`hmCheckTime`) angepasst. Nach einer Umstellung am Regler oder bei
  einem Kälteeinbruch ist das zu träge. Stündlich im Fenster `hmDayTimes`
  (07:00-21:00) wird geprüft: Ventile in mindestens 80 % der Messungen der
  letzten `hmDayMinutes` (120) über `hmDayValve` (50 %) und mindestens
  `hmDayColdRooms` (2) Räume `hmDayColdDelta` (0,8 K) unter Soll (Raumsensor,
  sonst Thermostatfühler) → Feineinstellung +1. Höchstens `hmDayMaxSteps` (2)
  Stufen pro Tag, Abstand mindestens `hmDayMinutes`, nie über `hmFineMax`.
  Nur nach oben; abgesenkt wird weiter nur in der Tagesauswertung.
  Nicht während Aufheizphase, Ofen, Klima, Sonnenabsenkung, Bedienung am
  Regler (`HumanAccess`), Standby oder Abwesenheit (`hmClimaPresence`).
  Readings `day_info`, `day_valve`, `day_cold`, `day_steps_today`.
- **`hmCurveRooms`:** nur diese Thermostate gehen in das Ventilmittel der Regeln
  `curve` und `tag` ein (leer = alle). Räume, die absichtlich kühl laufen
  (Schlafzimmer, Gästebad mit 12 °C), haben fast immer Ventil 0 und drücken
  sonst das Mittel – die Kurve sänke, obwohl die Wohnräume Wärme brauchen.
  „Zu kalt“, das höchste Ventil, Standby und Klima sehen weiter alle Räume.
- **`hmSimOnly`** (Default `tag`): Regeln, die auch bei `hmSimulate 0` nur
  simulieren, bis sie in `hmLive` stehen (`none` = keine). So startet eine neue
  Regel auch auf einer scharf geschalteten Anlage zuerst in der Simulation.
  Scharf schalten: `attr heizung hmLive …,tag`.

### Neu in v0.8.0

- **Regel `rampe`:** Steht im Wochenprofil eines Thermostats in `hmRampMinutes`
  (30) ein Sprung nach oben um mindestens `hmRampMinDelta` (1,5 K) an, setzt das
  Modul vorher den Zwischenwert mit `desiredTemperature auto <Mittel>`
  (19 -> 21: um 06:00 auf 20, ab 06:30 wieder Profil). Ein Funkbefehl je
  Thermostat, es bleibt im Automatikbetrieb. Nur Thermostate auf `auto`, deren
  Soll gerade dem Profil entspricht; mehrere Befehle im Abstand von 15 s.
  Startet wie jede neue Regel in der Simulation (`sim_rampe`, `rampe_info`).
- **Klima:** aus, wenn das Ventilmittel des Klima-Raums nach der Mindestlaufzeit
  unter `hmClimaStopValve` (10 %) liegt; kein Start bzw. sofort aus, wenn
  niemand zu Hause ist (`hmClimaPresence`, Standard `irgendwer:anwesend:on`,
  `none` = aus); kein Start in der Aufheizphase nach einem Sollwertsprung und
  wenn das Profil des Klima-Raums innerhalb der Mindestlaufzeit absenkt.

## Bedienung

- `set heizung evaluate` – Auswertung jetzt (im Simulationsmodus ohne Wirkung)
- `set heizung clearSamples` – Messwerte verwerfen
- `get heizung status` – aktuelle Auswertung als Text

Wichtige Readings: `valve_avg_now`, `valve_avg_24h`, `valve_max_room`,
`cold_room`, `samples_24h`, `fine_current`, `fine_target`, `decision`,
`standby_target`, `standby_info`, `verify`, `last_action`.

Vorlauftemperatur (ab v0.7.0, nur Anzeige): `flow_now`, `flow_avg_24h`,
`flow_min_24h`, `flow_max_24h`; die Tagesauswertung in `decision` nennt zusätzlich
„Vorlauf Ø … °C (min-max)“. Quelle ist `hmFlowSensor` (Gerät:Reading, Default
`mySolvis:S12.Vorlauftemperatur_HK1`, `none` = aus). Damit lässt sich ablesen, was
eine Änderung der Heizkurve am Vorlauf bewirkt. Keine Regel nutzt den Wert.

## Regeln einzeln scharf schalten

`hmSimulate 1` (Default) lässt alle Regeln nur rechnen. Regeln in `hmLive`
schalten trotzdem echt, z.B. erst `attr heizung hmLive ofen,saison`, später
weitere dazu. `hmSimulate 0` schaltet alle Regeln scharf. `get heizung status`
zeigt in der ersten Zeile, welche Regeln scharf sind.

## Attribute

Siehe Commandref im Modul (`help HeatManager`). Die wichtigsten:
`hmSimulate`, `hmLive`, `hmRules`, `hmThermostats`, `hmIgnore`, `hmRoomSensors`,
`hmHeater`, `hmFineReading`, `hmModeReading`, `hmFineMin`/`hmFineMax`,
`hmCheckTime`, `hmValveLow`/`hmValveHigh`, `hmColdDelta`/`hmColdMinutes`,
`hmRampIgnore`, `hmStandbyLow`/`hmStandbyHigh`/`hmStandbyMinTime`, `hmNotifyCmd`,
`hmFlowSensor`.

Die Messwerte überstehen einen FHEM-Neustart: sie werden stündlich im versteckten
Reading `.samples` abgelegt (landet im Statefile) und nach dem Start zurückgeholt.

## Test

```
sh t/run.sh
```

Läuft ohne FHEM (`t/fhem_stub.pl` ersetzt die FHEM-API, die Uhr ist simulierbar) und
prüft in `01_curve.t` … `04_klima.t` Heizkurve, Restore nach Neustart, Standby-Hysterese,
Ofen und Klima inkl. Stromausfall (70 Fälle, `01_curve.t` … `05_sonne_saison.t`).

Räume, die gerade von Ofen oder Klima beeinflusst werden, zählen nicht für die
Heizkurve (Reading `excluded_rooms`) – sonst würde die Kurve wegen der künstlich
geschlossenen Ventile zu weit sinken.
