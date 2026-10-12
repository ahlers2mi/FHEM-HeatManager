##############################################################################
# 98_HeatManager.pm
#
# FHEM-Modul zur Heizungsoptimierung: weniger Gas, ohne Komfort zu verlieren.
#
# Funktionen (jede einzeln über das Attribut hmRules schaltbar):
#   * curve: passt einmal täglich die Heizkurve an. Gestellt wird die
#     Feineinstellung des Wärmeerzeugers (bei der SolvisMax über SolvisClient
#     C15.TemperaturFeineinstellung_HK2, ±5 Stufen = Parallelverschiebung).
#     Grundlage sind die Ventilstellungen der Heizkörperthermostate und – wo
#     vorhanden – echte Raumsensoren: Ventile im Tagesmittel fast zu und kein
#     Raum zu kalt -> eine Stufe runter; ein Raum zu lange zu kalt oder ein
#     Ventil dauerhaft weit offen -> eine Stufe rauf. Höchstens eine Stufe pro
#     Tag, damit sich das träge Haus einpendeln kann. Aufheizphasen nach einem
#     Sollwertsprung (Wochenplan) und Räume, die gerade Ofen oder Klima
#     mitheizen, werden nicht gewertet. Ob der Wert am Regler angekommen ist,
#     wird nach 3 min geprüft (SolvisClient pausiert, solange jemand die
#     Fernbedienung benutzt).
#   * standby: Heizkreis in Standby, wenn die Ventile praktisch zu sind.
#     Getrennte Schwellen (Hysterese) und eine Mindestverweildauer verhindern
#     das ständige Hin- und Herschalten einer Ein-Schwellen-Logik.
#   * klima: steht das Ventil eines Raums lange weit offen, heizt das
#     Klimagerät mit, statt dass die Heizkurve für alle steigt. Nur im
#     Zeitfenster, mit Freigabe der Klima-Heizgrenze, genug Akku (oder
#     erlaubtem Netzstrom), begrenzten Starts und Mindestlauf-/Pausenzeiten.
#     Läuft die vorhandene Solar-Automatik der Klima (auto_on), hält sich das
#     Modul raus. Notfall (kein Netz am Wechselrichter) sperrt die Klima.
#   * ofen: erkennt am Stahleinsatz und an den Kacheln, ob der Kachelofen
#     brennt oder noch Wärme abgibt, und nimmt solange die Thermostate der
#     mitbeheizten Räume zurück. Danach wird der vorherige Zustand
#     wiederhergestellt – aber nur, wenn niemand inzwischen selbst etwas
#     eingestellt hat.
#
# Standard ist der Simulationsmodus (hmSimulate 1): das Modul misst, rechnet
# und schreibt in Readings (sim_<regel>, last_action), was es tun würde, schaltet
# aber nichts. Geschaltet wird ausschließlich über HeatManager_Do.
#
# Das Modul steuert nur über konfigurierbare Fremdgeräte (Attribute) und hält
# keine eigene Hardware.
#
# Autor:    ahlers2mi
# Version:  v0.3.0
# Lizenz:   GPL v2 oder höher (wie FHEM)
##############################################################################

package main;

use strict;
use warnings;
use Time::Local;
use JSON::PP;

# Von fhem.pl bereitgestellte Globals.
use vars qw($init_done %defs %attr $readingFnAttributes);

my $HM_VERSION = "0.3.0";

# Voreinstellungen aller Attribute. Sie passen zur Anlage des Autors und lassen
# sich einzeln per attr überschreiben; HeatManager_A liest Attribut oder Default.
my %HM_defaults = (
    # --- allgemein ---
    hmSimulate          => 1,                                   # 1 = nur rechnen und protokollieren
    hmRules             => "curve,standby,klima,ofen",          # aktive Regeln
    hmSampleInterval    => 300,                                 # Messintervall in s (min. 60)
    hmNotifyCmd         => "",                                  # FHEM-Befehl für Meldungen, $MSG wird ersetzt
    hmOutdoorSensor     => "Mobil3data:temperature",            # Außentemperatur
    # --- Thermostate / Räume ---
    hmThermostats       => "type=HeatingThermostat",            # devspec der Heizkörperthermostate
    hmIgnore            => "",                                  # nie bewerten (z. B. Keller)
    hmRoomSensors       => "",                                  # Thermostat:Raumsensor[:Reading]
    # --- Wärmeerzeuger ---
    hmHeater            => "mySolvis",                          # SolvisClient-Gerät
    hmFineReading       => "C15.TemperaturFeineinstellung_HK2", # Feineinstellung der Heizkurve
    hmModeReading       => "C12.Anlagenmodus_HK2",              # Betriebsart des Heizkreises
    # --- Regel curve ---
    hmFineMin           => -3,                                  # untere Grenze der Feineinstellung
    hmFineMax           => 2,                                   # obere Grenze
    hmCheckTime         => "05:00",                             # tägliche Auswertung
    hmValveLow          => 10,                                  # Ventilmittel 24 h darunter -> -1
    hmValveHigh         => 60,                                  # ein Raum im Mittel darüber -> +1
    hmColdDelta         => 0.5,                                 # K unter Soll gilt als zu kalt
    hmColdMinutes       => 60,                                  # so lange zu kalt -> +1
    hmRampIgnore        => 90,                                  # min nach Sollwertsprung nicht werten
    hmMinSamplesPct     => 50,                                  # Mindestanteil gemessener Zeit
    # --- Regel standby ---
    hmStandbyLow        => 1.5,                                 # Ventilmittel darunter -> Standby
    hmStandbyHigh       => 3,                                   # darüber -> wieder Betrieb
    hmStandbyMinTime    => 30,                                  # min Mindestverweildauer je Zustand
    hmStandbyModeOn     => "Standby",                           # Wert für hmModeReading: Standby
    hmStandbyModeOff    => "Timer",                             # Wert für hmModeReading: Betrieb
    # --- Regel ofen ---
    hmOvenSensor        => "MQTT2_MAX6675_01:Temperatur",       # Thermoelement am Stahleinsatz
    hmOvenTileSensor    => "XMI_158d00045d0119:temperature",    # Sensor auf den Kacheln
    hmOvenBurn          => 60,                                  # Einsatz darüber -> brennt
    hmOvenStore         => 35,                                  # Kacheln darüber -> speichert (Hyst. 2 K)
    hmOvenTemp          => 17,                                  # Soll der Ofenräume, solange er heizt
    hmOvenRooms         => "MAX_040549 MAX_0437c3 MAX_06e2ff",  # Wohnzimmer, Gästezimmer, Bad Altbau
    # --- Regel klima ---
    hmClimaRoom         => "MAX_040549",                        # Thermostat, dessen Ventil auslöst
    hmClimaDevice       => "d_clima_gaestezimmer",              # Automatik-Dummy (autoTemperature, auto_on)
    hmClimaAc           => "net_ac_86E6",                       # Klimagerät (power, mode)
    hmClimaGate         => "d_klima_heizgrenze",                # Reading freigabe on/off
    hmClimaAffected     => "MAX_0404e5 MAX_040549",             # Räume, die die Klima mitheizt
    hmClimaValve        => 50,                                  # Ventilmittel % für den Start
    hmClimaValveMinutes => 60,                                  # gemittelt über diese Minuten
    hmClimaTimes        => "07:00-20:30",                       # Zeitfenster (abends: Nachbarin)
    hmClimaSetTemp      => 26,                                  # 26 an der Klima ~ 22 im Raum
    hmClimaSoc          => 60,                                  # Akku-Mindeststand %
    hmClimaSocReading   => "rem_MQTT2_SMART_SHUNT1:data_state_of_charge_shunt_state",
    hmClimaGrid         => 0,                                   # 1 = auch mit Netzstrom
    hmClimaMinOutdoor   => 3,                                   # Netzstrom erst ab dieser Außentemp.
    hmClimaMinRun       => 60,                                  # min Mindestlaufzeit
    hmClimaMinOff       => 60,                                  # min Mindestpause
    hmClimaMaxStarts    => 2,                                   # Starts pro Tag
    # --- Notfall (kein Netz) ---
    hmGridSensor        => "MQTT2_Wechselrichter1:netzspannung",# Netzspannung am Wechselrichter
    hmGridMin           => 100,                                 # V darunter = Notfall
    hmEmergencyReading  => "d_solar:index",                     # Solarindex der vorhandenen Logik
    hmEmergencyBelow    => -40,                                 # <= Wert = Notfall (n_d_solar_index)
);

# ----------------------------------------------------------------------------
# HeatManager_Initialize
#   Registriert die Callback-Funktionen und die Attributliste.
# ----------------------------------------------------------------------------
sub HeatManager_Initialize {
    my ($hash) = @_;

    $hash->{DefFn}   = \&HeatManager_Define;
    $hash->{UndefFn} = \&HeatManager_Undef;
    $hash->{SetFn}   = \&HeatManager_Set;
    $hash->{GetFn}   = \&HeatManager_Get;
    $hash->{AttrFn}  = \&HeatManager_Attr;

    $hash->{AttrList} =
          "disable:0,1 "
        . "hmSimulate:1,0 "
        . "hmRules:multiple-strict,curve,standby,klima,ofen "
        . "hmSampleInterval hmNotifyCmd:textField-long hmOutdoorSensor "
        # --- Thermostate / Räume ---
        . "hmThermostats hmIgnore hmRoomSensors:textField-long "
        # --- Wärmeerzeuger ---
        . "hmHeater hmFineReading hmModeReading "
        # --- curve ---
        . "hmFineMin hmFineMax hmCheckTime hmValveLow hmValveHigh "
        . "hmColdDelta hmColdMinutes hmRampIgnore hmMinSamplesPct "
        # --- standby ---
        . "hmStandbyLow hmStandbyHigh hmStandbyMinTime hmStandbyModeOn hmStandbyModeOff "
        # --- ofen ---
        . "hmOvenSensor hmOvenTileSensor hmOvenBurn hmOvenStore hmOvenTemp hmOvenRooms "
        # --- klima ---
        . "hmClimaRoom hmClimaDevice hmClimaAc hmClimaGate hmClimaAffected hmClimaValve "
        . "hmClimaValveMinutes hmClimaTimes hmClimaSetTemp hmClimaSoc hmClimaSocReading "
        . "hmClimaGrid:0,1 hmClimaMinOutdoor hmClimaMinRun hmClimaMinOff hmClimaMaxStarts "
        # --- Notfall ---
        . "hmGridSensor hmGridMin hmEmergencyReading hmEmergencyBelow "
        . $readingFnAttributes;
    return undef;
}

# ----------------------------------------------------------------------------
# HeatManager_A
#   Attribut lesen, sonst Modul-Default.
# ----------------------------------------------------------------------------
sub HeatManager_A {
    my ($name, $a) = @_;
    return AttrVal($name, $a, $HM_defaults{$a});
}

# ----------------------------------------------------------------------------
# HeatManager_RuleOn
#   Ist die Regel in hmRules aktiv?
# ----------------------------------------------------------------------------
sub HeatManager_RuleOn {
    my ($name, $rule) = @_;
    return (grep { $_ eq $rule } split(/,/, HeatManager_A($name, "hmRules"))) ? 1 : 0;
}

# ----------------------------------------------------------------------------
# HeatManager_Define
#   define <name> HeatManager
#   Messwerte werden erst nach dem Laden des Statefiles wiederhergestellt,
#   deshalb per Timer (HeatManager_restoreState) und nicht hier.
# ----------------------------------------------------------------------------
sub HeatManager_Define {
    my ($hash, $def) = @_;
    my @a = split('[ \t][ \t]*', $def);

    return "Usage: define <name> HeatManager" if (@a != 2);

    $hash->{VERSION}  = $HM_VERSION;
    $hash->{FVERSION} = "98_HeatManager.pm:v$HM_VERSION";
    $hash->{helper}{samples} //= [];   # Messwerte der letzten 26 h
    $hash->{helper}{desired} //= {};   # letzter bekannter Sollwert je Thermostat

    readingsSingleUpdate($hash, "state", "initialized", 1);
    RemoveInternalTimer($hash);
    InternalTimer(gettimeofday() + 3,  "HeatManager_restoreState", $hash, 0);
    InternalTimer(gettimeofday() + 30, "HeatManager_Sample",       $hash, 0);
    HeatManager_ScheduleCheck($hash);
    return undef;
}

# ----------------------------------------------------------------------------
# HeatManager_Undef
#   delete/rereadcfg: alle eigenen Timer entfernen.
# ----------------------------------------------------------------------------
sub HeatManager_Undef {
    my ($hash) = @_;
    RemoveInternalTimer($hash);
    RemoveInternalTimer("check:"  . $hash->{NAME});
    RemoveInternalTimer("verify:" . $hash->{NAME});
    return undef;
}

# ----------------------------------------------------------------------------
# HeatManager_Attr
#   Attribute prüfen; eine neue hmCheckTime plant die Tagesauswertung um.
# ----------------------------------------------------------------------------
sub HeatManager_Attr {
    my ($cmd, $name, $attr, $val) = @_;
    my $hash = $defs{$name};

    if ($cmd eq "set" && $attr eq "hmCheckTime") {
        return "hmCheckTime: HH:MM erwartet" if ($val !~ /^\d\d:\d\d$/);
    }
    if ($cmd eq "set" && $attr =~ /^hm(FineMin|FineMax|SampleInterval|ValveLow|ValveHigh|ColdDelta|ColdMinutes|RampIgnore|MinSamplesPct|StandbyLow|StandbyHigh|StandbyMinTime|OvenBurn|OvenStore|OvenTemp|ClimaValve|ClimaValveMinutes|ClimaSetTemp|ClimaSoc|ClimaMinOutdoor|ClimaMinRun|ClimaMinOff|ClimaMaxStarts|GridMin|EmergencyBelow)$/) {
        return "$attr: Zahl erwartet" if ($val !~ /^-?\d+(\.\d+)?$/);
    }
    if ($attr eq "hmCheckTime" && $init_done && $hash) {
        HeatManager_ScheduleCheck($hash, $cmd eq "set" ? $val : $HM_defaults{hmCheckTime});
    }
    return undef;
}

# ----------------------------------------------------------------------------
# HeatManager_restoreState
#   Holt nach einem Neustart die Messwerte aus dem versteckten Reading
#   .samples zurück. Hintergrund: $hash->{helper} schreibt FHEM NICHT ins
#   Statefile, Readings dagegen schon (wie bei PoolControl die Tageslaufzeit).
#   Ohne das bräuchte die Heizkurve nach jedem Neustart wieder einen halben
#   Tag, bis sie entscheiden darf. Genau einmal pro FHEM-Laufzeit.
# ----------------------------------------------------------------------------
sub HeatManager_restoreState {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    return undef if ($hash->{helper}{restoreDone});
    $hash->{helper}{restoreDone} = 1;
    return undef if (@{$hash->{helper}{samples} // []});    # defmod im Betrieb: Speicher ist aktueller

    my $json = ReadingsVal($name, ".samples", "");
    return undef if ($json eq "");
    my $s = eval { decode_json($json) };
    if (ref($s) ne "ARRAY") {
        Log3($name, 2, "HeatManager $name: .samples nicht lesbar, beginne neu");
        return undef;
    }
    my $now = time();
    $hash->{helper}{samples} = [ grep { $now - $_->{t} < 26 * 3600 } @$s ];
    Log3($name, 3, "HeatManager $name: " . scalar(@{$hash->{helper}{samples}})
                 . " Messwerte nach Neustart übernommen");
    return undef;
}

# ----------------------------------------------------------------------------
# HeatManager_saveState
#   Messwerte ins versteckte Reading .samples (landet im Statefile). Einmal pro
#   Stunde reicht - verloren geht höchstens die letzte Stunde.
# ----------------------------------------------------------------------------
sub HeatManager_saveState {
    my ($hash) = @_;
    my $now = time();
    return undef if ($now - ($hash->{helper}{lastSave} // 0) < 3600);
    $hash->{helper}{lastSave} = $now;
    readingsSingleUpdate($hash, ".samples", encode_json($hash->{helper}{samples}), 0);
    return undef;
}

# ============================================================================
# Messen
# ============================================================================

# ----------------------------------------------------------------------------
# HeatManager_Thermostats
#   Thermostate laut hmThermostats (devspec) ohne hmIgnore.
# ----------------------------------------------------------------------------
sub HeatManager_Thermostats {
    my ($name) = @_;
    my %ign = map { $_ => 1 } split(/[,\s]+/, HeatManager_A($name, "hmIgnore"));
    return grep { !$ign{$_} && defined($defs{$_}) }
           devspec2array(HeatManager_A($name, "hmThermostats"));
}

# ----------------------------------------------------------------------------
# HeatManager_SensorMap
#   hmRoomSensors "MAX_040549:Mobil5data MAX_0404d9:Mobil1data:temperature"
#   -> { Thermostat => [Gerät, Reading] }
# ----------------------------------------------------------------------------
sub HeatManager_SensorMap {
    my ($name) = @_;
    my %m;
    foreach my $e (split(/[\s,]+/, HeatManager_A($name, "hmRoomSensors"))) {
        my ($t, $d, $r) = split(/:/, $e);
        next if (!$t || !$d);
        $m{$t} = [$d, $r // "temperature"];
    }
    return \%m;
}

# ----------------------------------------------------------------------------
# HeatManager_SensorVal
#   "Gerät:Reading" lesen und die erste Zahl liefern (Einheiten wie " C" oder
#   " %" werden ignoriert); undef, wenn nicht vorhanden.
# ----------------------------------------------------------------------------
sub HeatManager_SensorVal {
    my ($spec) = @_;
    my ($d, $r) = split(/:/, $spec // "");
    return undef if (!$d || !$r);
    my $v = ReadingsVal($d, $r, undef);
    return (defined($v) && $v =~ /^(-?[\d.]+)/) ? $1 : undef;
}

# ----------------------------------------------------------------------------
# HeatManager_Sample
#   Messung alle hmSampleInterval Sekunden:
#     1. Ofenregel ausführen und Ofen-/Klima-beeinflusste Räume bestimmen.
#     2. Je Thermostat Ventil und "zu kalt" erfassen. Ausgeblendet werden
#        Thermostate ohne Zahlen-Sollwert (off/on), Aufheizphasen nach einem
#        Sollwertsprung und Räume, die Ofen oder Klima gerade mitheizen.
#     3. Standby- und Klimaregel aufrufen.
#   Die Heizkurve wertet die gesammelten Messwerte einmal täglich aus.
# ----------------------------------------------------------------------------
sub HeatManager_Sample {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $iv   = HeatManager_A($name, "hmSampleInterval");
    $iv = 60 if ($iv < 60);
    InternalTimer(gettimeofday() + $iv, "HeatManager_Sample", $hash, 0);   # nächste Messung
    return undef if (IsDisabled($name));
    HeatManager_restoreState($hash);       # falls der Timer dafür noch nicht lief

    my $now  = time();
    my $smap = HeatManager_SensorMap($name);
    my $ramp = HeatManager_A($name, "hmRampIgnore") * 60;
    my $cd   = HeatManager_A($name, "hmColdDelta");
    my (%valve, %cold, %ramp, %excl);
    my ($sum, $n) = (0, 0);

    # 1. Ofen und Klima schließen Ventile künstlich -> Räume nicht für die Kurve werten
    my $oven = HeatManager_RuleOn($name, "ofen") ? HeatManager_Oven($hash) : "aus";
    if ($oven ne "aus") {
        $excl{$_} = "ofen" for split(/[\s,]+/, HeatManager_A($name, "hmOvenRooms"));
    }
    my $ac     = HeatManager_A($name, "hmClimaAc");
    my $acHeat = ReadingsVal($ac, "power", "Off") eq "On" && ReadingsVal($ac, "mode", "") =~ /heat/i;
    if ($acHeat) {
        $excl{$_} = "klima" for split(/[\s,]+/, HeatManager_A($name, "hmClimaAffected"));
    }

    # 2. Thermostate
    foreach my $t (HeatManager_Thermostats($name)) {
        my $des = ReadingsVal($t, "desiredTemperature", "off");
        my $v   = ReadingsVal($t, "valveposition", undef);
        next if (!defined($v) || $v !~ /^[\d.]+$/);

        # Sollwertsprung merken (Wochenplan) -> danach Aufheizphase ausblenden
        my $old = $hash->{helper}{desired}{$t};
        if (!defined($old) || $old ne $des) {
            $hash->{helper}{desired}{$t} = $des;
            $hash->{helper}{desiredChange}{$t} = $now if (defined($old));
        }

        $sum += $v; $n++;                                  # für das Standby-Mittel
        $hash->{helper}{valveNow}{$t} = $v;                # aktueller Wert für die Klima-Regel

        next if ($des !~ /^[\d.]+$/);                      # off/on: keine Bewertung
        next if ($excl{$t});                               # Ofen/Klima heizt mit
        if (($now - ($hash->{helper}{desiredChange}{$t} // 0)) < $ramp) {
            $ramp{$t} = 1;                                 # Aufheizphase
            next;
        }
        $valve{$t} = $v;                                   # zählt für die Heizkurve

        # "zu kalt" nur mit echtem Raumsensor - der MAX-Fühler sitzt am Heizkörper
        if ($smap->{$t}) {
            my $temp = ReadingsVal($smap->{$t}[0], $smap->{$t}[1], undef);
            $cold{$t} = ($temp < $des - $cd) ? 1 : 0
                if (defined($temp) && $temp =~ /^-?[\d.]+$/);
        }
    }
    # Mittel über ALLE Thermostate (auch ausgeblendete) - Grundlage für Standby
    my $avg = $n ? $sum / $n : 0;

    push @{$hash->{helper}{samples}}, { t => $now, valve => \%valve, cold => \%cold };
    @{$hash->{helper}{samples}} = grep { $now - $_->{t} < 26 * 3600 } @{$hash->{helper}{samples}};
    HeatManager_saveState($hash);

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "valve_avg_now",  sprintf("%.1f", $avg));
    readingsBulkUpdate($hash, "ramp_rooms",     join(",", sort keys %ramp) || "none");
    readingsBulkUpdate($hash, "excluded_rooms", join(",", map { "$_:$excl{$_}" } sort keys %excl) || "none");
    readingsEndUpdate($hash, 1);

    # 3. laufende Regeln
    HeatManager_Standby($hash, $avg) if (HeatManager_RuleOn($name, "standby"));
    HeatManager_Clima($hash, $hash->{helper}{valveNow}{HeatManager_A($name, "hmClimaRoom")})
        if (HeatManager_RuleOn($name, "klima"));
    return undef;
}

# ============================================================================
# Regel standby
# ============================================================================

# ----------------------------------------------------------------------------
# HeatManager_Standby
#   Heizkreis in Standby, wenn das Ventilmittel unter hmStandbyLow fällt;
#   zurück in Betrieb erst über hmStandbyHigh. Jeder Zustand bleibt mindestens
#   hmStandbyMinTime. Ausgangszustand ist der aktuelle Modus am Wärmeerzeuger.
# ----------------------------------------------------------------------------
sub HeatManager_Standby {
    my ($hash, $avg) = @_;
    my $name   = $hash->{NAME};
    my $heater = HeatManager_A($name, "hmHeater");
    my $rd     = HeatManager_A($name, "hmModeReading");
    my $on     = HeatManager_A($name, "hmStandbyModeOn");
    my $off    = HeatManager_A($name, "hmStandbyModeOff");
    my $cur    = ReadingsVal($heater, $rd, "");
    my $want   = ReadingsVal($name, "standby_target", $cur eq $on ? $on : $off);
    my $since  = ReadingsVal($name, "standby_since", 0);
    my $minT   = HeatManager_A($name, "hmStandbyMinTime") * 60;
    my $now    = time();

    # Zielzustand mit Hysterese
    my $new = $want;
    if ($want ne $on && $avg < HeatManager_A($name, "hmStandbyLow")) {
        $new = $on;
    } elsif ($want eq $on && $avg > HeatManager_A($name, "hmStandbyHigh")) {
        $new = $off;
    }
    return undef if ($new eq $want);                        # nichts zu tun
    if (($now - $since) < $minT) {                          # zu früh nach dem letzten Wechsel
        readingsSingleUpdate($hash, "standby_info", "Wechsel nach $new wartet (Mindestzeit)", 1);
        return undef;
    }
    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "standby_target", $new);
    readingsBulkUpdate($hash, "standby_since",  $now);
    readingsBulkUpdate($hash, "standby_info",   sprintf("%s bei Ventilen %.1f %%", $new, $avg));
    readingsEndUpdate($hash, 1);
    HeatManager_Do($hash, "set $heater $rd $new", "standby");
    return undef;
}

# ============================================================================
# Regel curve
# ============================================================================

# ----------------------------------------------------------------------------
# HeatManager_ScheduleCheck
#   Nächsten Termin der Tagesauswertung setzen (heute oder morgen).
# ----------------------------------------------------------------------------
sub HeatManager_ScheduleCheck {
    my ($hash, $time) = @_;
    my $name = $hash->{NAME};
    $time //= HeatManager_A($name, "hmCheckTime");
    my ($h, $m) = split(/:/, $time);
    my @lt   = localtime(time());
    my $next = timelocal(0, $m, $h, $lt[3], $lt[4], $lt[5]);
    $next += 86400 if ($next <= time() + 5);
    RemoveInternalTimer("check:$name");
    InternalTimer($next, "HeatManager_CheckTimer", "check:$name", 0);
    readingsSingleUpdate($hash, "next_check", FmtDateTime($next), 0);
    return undef;
}

# ----------------------------------------------------------------------------
# HeatManager_CheckTimer
#   Timer der Tagesauswertung: neu planen, dann auswerten.
# ----------------------------------------------------------------------------
sub HeatManager_CheckTimer {
    my ($arg) = @_;
    my (undef, $name) = split(/:/, $arg, 2);
    my $hash = $defs{$name};
    return undef if (!$hash);
    HeatManager_ScheduleCheck($hash);
    HeatManager_Curve($hash) if (!IsDisabled($name) && HeatManager_RuleOn($name, "curve"));
    return undef;
}

# ----------------------------------------------------------------------------
# HeatManager_Evaluate
#   Wertet die Messwerte der letzten 24 h aus und liefert die Entscheidung
#   (step +1 / -1 / 0) samt Begründung. Schaltet nichts.
#   Reihenfolge = Priorität: erst Datenlage, dann Komfort (+1), dann Sparen (-1).
# ----------------------------------------------------------------------------
sub HeatManager_Evaluate {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $now  = time();
    my @s    = grep { $now - $_->{t} <= 24 * 3600 } @{$hash->{helper}{samples}};
    my $iv   = HeatManager_A($name, "hmSampleInterval");
    my $expected = 24 * 3600 / ($iv < 60 ? 60 : $iv);

    # Summen je Raum: Ventil und Minuten "zu kalt"
    my (%vsum, %vn, %cmin);
    foreach my $smp (@s) {
        foreach my $t (keys %{$smp->{valve}}) { $vsum{$t} += $smp->{valve}{$t}; $vn{$t}++; }
        foreach my $t (keys %{$smp->{cold}})  { $cmin{$t} += $smp->{cold}{$t} * $iv / 60; }
    }
    # Mittel je Raum, dann über alle Räume; dazu Raum mit höchstem Ventil
    # und Raum, der am längsten zu kalt war
    my %vavg = map { $_ => $vsum{$_} / $vn{$_} } keys %vsum;
    my ($all, $cnt) = (0, 0);
    foreach (keys %vavg) { $all += $vavg{$_}; $cnt++; }
    my $avg = $cnt ? $all / $cnt : 0;
    my ($maxRoom)  = sort { $vavg{$b} <=> $vavg{$a} } keys %vavg;
    my ($coldRoom) = sort { $cmin{$b} <=> $cmin{$a} } keys %cmin;
    my $coldMin = $coldRoom ? $cmin{$coldRoom} : 0;

    my %r = (
        samples   => scalar(@s),
        samplePct => $expected ? int(100 * @s / $expected) : 0,
        valveAvg  => $avg,
        maxRoom   => $maxRoom // "",
        maxValve  => $maxRoom ? $vavg{$maxRoom} : 0,
        coldRoom  => $coldMin > 0 ? $coldRoom : "",
        coldMin   => $coldMin,
        step      => 0,
        reason    => "",
    );
    if ($r{samplePct} < HeatManager_A($name, "hmMinSamplesPct")) {
        $r{reason} = "zu wenig Messwerte ($r{samplePct} %)";
    } elsif ($cnt == 0) {
        $r{reason} = "keine Thermostate im Heizbetrieb";
    } elsif ($coldMin >= HeatManager_A($name, "hmColdMinutes")) {
        $r{step} = 1;  $r{reason} = sprintf("%s %d min zu kalt", $coldRoom, $coldMin);
    } elsif ($r{maxValve} >= HeatManager_A($name, "hmValveHigh")) {
        $r{step} = 1;  $r{reason} = sprintf("%s Ventil im Mittel %.0f %%", $maxRoom, $r{maxValve});
    } elsif ($avg < HeatManager_A($name, "hmValveLow") && $coldMin == 0) {
        $r{step} = -1; $r{reason} = sprintf("Ventile im Mittel %.1f %%, kein Raum zu kalt", $avg);
    } else {
        $r{reason} = sprintf("im Zielbereich (Ventile %.1f %%)", $avg);
    }
    return \%r;
}

# ----------------------------------------------------------------------------
# HeatManager_Curve
#   Entscheidung anwenden: Ziel innerhalb hmFineMin/hmFineMax setzen, Readings
#   schreiben und - außer in der Simulation - die Übernahme am Regler prüfen.
#   $manual = 1 bei "set evaluate".
# ----------------------------------------------------------------------------
sub HeatManager_Curve {
    my ($hash, $manual) = @_;
    my $name   = $hash->{NAME};
    my $heater = HeatManager_A($name, "hmHeater");
    my $rd     = HeatManager_A($name, "hmFineReading");
    my $cur    = ReadingsVal($heater, $rd, undef);
    my $e      = HeatManager_Evaluate($hash);

    my $target = (defined($cur) && $cur =~ /^-?\d+$/) ? $cur : undef;
    my $info   = $e->{reason};
    if (!defined($target)) {
        $info = "Feineinstellung $heater:$rd nicht lesbar";
    } elsif ($e->{step}) {
        my $t = $target + $e->{step};
        my ($mn, $mx) = (HeatManager_A($name, "hmFineMin"), HeatManager_A($name, "hmFineMax"));
        $t = $mn if ($t < $mn);
        $t = $mx if ($t > $mx);
        $info .= " -> Grenze erreicht" if ($t == $target);
        $target = $t;
    }

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "valve_avg_24h",  sprintf("%.1f", $e->{valveAvg}));
    readingsBulkUpdate($hash, "valve_max_room", $e->{maxRoom} ? sprintf("%s:%.0f", $e->{maxRoom}, $e->{maxValve}) : "none");
    readingsBulkUpdate($hash, "cold_room",      $e->{coldRoom} ? sprintf("%s:%d", $e->{coldRoom}, $e->{coldMin}) : "none");
    readingsBulkUpdate($hash, "samples_24h",    "$e->{samples} ($e->{samplePct} %)");
    readingsBulkUpdate($hash, "fine_current",   $cur // "?");
    readingsBulkUpdate($hash, "fine_target",    $target // "?");
    readingsBulkUpdate($hash, "decision",       $info);
    readingsBulkUpdate($hash, "state",          ($manual ? "Auswertung: " : "") . $info);
    readingsEndUpdate($hash, 1);

    if (defined($target) && defined($cur) && $target != $cur) {
        HeatManager_Do($hash, "set $heater $rd $target", "curve",
                       "Heizkurve $rd $cur -> $target ($e->{reason})");
        HeatManager_VerifyLater($hash, $heater, $rd, $target, 1)
            if (!HeatManager_A($name, "hmSimulate"));
    }
    return $info;
}

# ============================================================================
# Regel ofen
# ============================================================================

# ----------------------------------------------------------------------------
# HeatManager_OvenState
#   Zustand aus Einsatz- und Kacheltemperatur: Einsatz > hmOvenBurn -> brennt,
#   Kacheln > hmOvenStore -> speichert, sonst aus. Die Kacheln geben noch
#   Stunden Wärme ab; die 2 K Hysterese verhindert Flattern an der Schwelle.
# ----------------------------------------------------------------------------
sub HeatManager_OvenState {
    my ($hash) = @_;
    my $name  = $hash->{NAME};
    my $ins   = HeatManager_SensorVal(HeatManager_A($name, "hmOvenSensor"));
    my $tile  = HeatManager_SensorVal(HeatManager_A($name, "hmOvenTileSensor"));
    my $old   = ReadingsVal($name, "oven_state", "aus");
    my $store = HeatManager_A($name, "hmOvenStore");
    my $st    = "aus";
    if (defined($ins) && $ins > HeatManager_A($name, "hmOvenBurn")) {
        $st = "brennt";
    } elsif (defined($tile) && ($tile > $store || ($old ne "aus" && $tile > $store - 2))) {
        $st = "speichert";
    }
    return ($st, $ins, $tile);
}

# ----------------------------------------------------------------------------
# HeatManager_Oven
#   Heizt der Ofen, gehen die Thermostate in hmOvenRooms auf hmOvenTemp. Der
#   vorherige Zustand (auto oder Wert) liegt im Reading oven_prev_<thermostat>
#   und übersteht damit Neustarts. Beim Erkalten wird er wiederhergestellt -
#   aber nur, wenn noch unser Wert eingestellt ist; hat jemand inzwischen
#   selbst etwas eingestellt, bleibt das stehen.
#   Thermostate, die aus sind oder ohnehin niedriger stehen, bleiben unberührt.
# ----------------------------------------------------------------------------
sub HeatManager_Oven {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my ($st, $ins, $tile) = HeatManager_OvenState($hash);
    my $old  = ReadingsVal($name, "oven_state", "aus");
    my $otmp = HeatManager_A($name, "hmOvenTemp");
    my $sim  = HeatManager_A($name, "hmSimulate");

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "oven_state",  $st);
    readingsBulkUpdate($hash, "oven_insert", $ins  // "?");
    readingsBulkUpdate($hash, "oven_tiles",  $tile // "?");
    readingsEndUpdate($hash, 1);

    foreach my $t (split(/[\s,]+/, HeatManager_A($name, "hmOvenRooms"))) {
        next if (!$t || !defined($defs{$t}));
        my $prevRd = "oven_prev_$t";
        my $prev   = ReadingsVal($name, $prevRd, "");
        my $des    = ReadingsVal($t, "desiredTemperature", "off");
        if ($st ne "aus") {
            next if ($prev ne "");                               # schon abgesenkt
            next if ($des !~ /^[\d.]+$/ || $des <= $otmp);       # aus/niedriger: nichts tun
            my $mode = ReadingsVal($t, "mode", "manual") eq "auto" ? "auto" : $des;
            readingsSingleUpdate($hash, $prevRd, $mode, 0);
            HeatManager_Do($hash, "set $t desiredTemperature $otmp", "ofen",
                           "Ofen $st: $t auf $otmp (vorher $mode)");
        } elsif ($prev ne "") {
            # nur zurücksetzen, wenn der Wert noch unserer ist
            if ($sim || ($des =~ /^[\d.]+$/ && $des == $otmp)) {
                HeatManager_Do($hash, "set $t desiredTemperature $prev", "ofen",
                               "Ofen aus: $t zurück auf $prev");
            }
            readingsDelete($hash, $prevRd);
        }
    }
    if ($st ne $old) {
        readingsSingleUpdate($hash, "oven_since", FmtDateTime(time()), 1);
        Log3($name, 3, "HeatManager $name: Ofen $old -> $st");
    }
    return $st;
}

# ============================================================================
# Regel klima
# ============================================================================

# ----------------------------------------------------------------------------
# HeatManager_InWindow
#   Liegt die aktuelle Uhrzeit in einem der Fenster "HH:MM-HH:MM[,...]"?
# ----------------------------------------------------------------------------
sub HeatManager_InWindow {
    my ($win) = @_;
    my @lt  = localtime(time());
    my $now = sprintf("%02d:%02d", $lt[2], $lt[1]);
    foreach my $w (split(/[\s,]+/, $win // "")) {
        my ($a, $b) = split(/-/, $w);
        next if (!$a || !$b);
        return 1 if ($now ge $a && $now lt $b);
    }
    return 0;
}

# ----------------------------------------------------------------------------
# HeatManager_Emergency
#   Notfall = kein Netz am Wechselrichter. Erkannt wie in der vorhandenen
#   Solarsteuerung: Netzspannung unter hmGridMin ODER Solarindex
#   (hmEmergencyReading, d_solar:index) bei hmEmergencyBelow oder darunter -
#   dann schaltet n_d_solar_index alle großen Verbraucher ab. Das Modul startet
#   die Klima dann nie und beendet einen eigenen Lauf sofort. Fehlende Werte
#   gelten nicht als Notfall.
# ----------------------------------------------------------------------------
sub HeatManager_Emergency {
    my ($name) = @_;
    my $v = HeatManager_SensorVal(HeatManager_A($name, "hmGridSensor"));
    return 1 if (defined($v) && $v < HeatManager_A($name, "hmGridMin"));
    my $i = HeatManager_SensorVal(HeatManager_A($name, "hmEmergencyReading"));
    return 1 if (defined($i) && $i <= HeatManager_A($name, "hmEmergencyBelow"));
    return 0;
}

# ----------------------------------------------------------------------------
# HeatManager_ClimaEnergyOk
#   Darf die Klima Strom verbrauchen? Akku über hmClimaSoc - beim Weiterlaufen
#   mit $margin Puffer, damit sie nicht an der Schwelle flattert - oder, falls
#   hmClimaGrid 1, Netzstrom ab hmClimaMinOutdoor Außentemperatur (Effizienz).
# ----------------------------------------------------------------------------
sub HeatManager_ClimaEnergyOk {
    my ($name, $margin) = @_;
    my $soc = HeatManager_SensorVal(HeatManager_A($name, "hmClimaSocReading"));
    return (1, "Akku $soc %")
        if (defined($soc) && $soc >= HeatManager_A($name, "hmClimaSoc") - ($margin // 0));
    if (HeatManager_A($name, "hmClimaGrid")) {
        my $out = HeatManager_SensorVal(HeatManager_A($name, "hmOutdoorSensor"));
        return (1, "Netzstrom, aussen $out C")
            if (defined($out) && $out >= HeatManager_A($name, "hmClimaMinOutdoor"));
    }
    return (0, "Akku " . ($soc // "?") . " %");
}

# ----------------------------------------------------------------------------
# HeatManager_Clima
#   Bei jeder Messung aufgerufen. clima_state "an" heißt: das Modul hat die
#   Klima gestartet - nur dann schaltet es sie auch wieder aus. Gesteuert wird
#   über autoTemperature des Automatik-Dummys; damit greifen dessen Logik und
#   die Klima-Heizgrenze weiter. Das Modul hält sich raus, wenn der Dummy
#   nicht auf auto steht (Nutzer hat übernommen) oder die vorhandene
#   Solar-Automatik läuft (Reading auto_on = on, gesetzt von n_d_solar_index).
# ----------------------------------------------------------------------------
sub HeatManager_Clima {
    my ($hash, $valveNow) = @_;
    my $name  = $hash->{NAME};
    my $room  = HeatManager_A($name, "hmClimaRoom");
    my $dummy = HeatManager_A($name, "hmClimaDevice");
    my $ac    = HeatManager_A($name, "hmClimaAc");
    my $now   = time();
    return undef if (!$room || !defined($defs{$dummy}));

    # gleitendes Ventilmittel des Raums über hmClimaValveMinutes
    my $win = HeatManager_A($name, "hmClimaValveMinutes") * 60;
    push @{$hash->{helper}{climaValve}}, [$now, $valveNow] if (defined($valveNow));
    @{$hash->{helper}{climaValve}} = grep { $now - $_->[0] <= $win } @{$hash->{helper}{climaValve} // []};
    my @v  = map { $_->[1] } @{$hash->{helper}{climaValve}};
    my $vs = 0; $vs += $_ for @v;
    my $avg = @v ? $vs / @v : 0;
    # erst werten, wenn der Zeitraum (bis auf ein Intervall) gefüllt ist
    my $siv  = HeatManager_A($name, "hmSampleInterval");
    my $full = (@v && ($now - $hash->{helper}{climaValve}[0][0]) >= $win - $siv) ? 1 : 0;

    # Startzähler täglich zurücksetzen
    my @lt  = localtime(time());
    my $day = sprintf("%04d-%02d-%02d", $lt[5] + 1900, $lt[4] + 1, $lt[3]);
    if (ReadingsVal($name, "clima_day", "") ne $day) {
        readingsBeginUpdate($hash);
        readingsBulkUpdate($hash, "clima_day", $day);
        readingsBulkUpdate($hash, "clima_starts_today", 0);
        readingsEndUpdate($hash, 0);
    }

    my $state   = ReadingsVal($name, "clima_state", "aus");
    my $since   = ReadingsVal($name, "clima_since", 0);
    my $inWin   = HeatManager_InWindow(HeatManager_A($name, "hmClimaTimes"));
    my $frei    = ReadingsVal(HeatManager_A($name, "hmClimaGate"), "freigabe", "on") eq "on";
    my $auto    = ReadingsVal($dummy, "mode", "") eq "auto";
    my $solar   = ReadingsVal($dummy, "auto_on", "off") eq "on";
    my $acOn    = ReadingsVal($ac, "power", "Off") eq "On";
    my ($eok, $etxt) = HeatManager_ClimaEnergyOk($name, $state eq "an" ? 10 : 0);
    my $smap    = HeatManager_SensorMap($name);
    my $rtemp   = $smap->{$room} ? HeatManager_SensorVal("$smap->{$room}[0]:$smap->{$room}[1]") : undef;
    my $target  = AttrVal($room, "desiredTemperature", 20);
    my $notfall = HeatManager_Emergency($name);

    readingsSingleUpdate($hash, "clima_valve_avg", sprintf("%.0f", $avg), 0);
    readingsSingleUpdate($hash, "notfall", $notfall ? "on" : "off", 1)
        if (ReadingsVal($name, "notfall", "") ne ($notfall ? "on" : "off"));

    # --- läuft (von uns gestartet): abschalten? ---
    if ($state eq "an") {
        # Nutzer oder Solar-Automatik haben übernommen -> nur loslassen, nichts schalten
        my $other = !$auto ? "Nutzer (mode " . ReadingsVal($dummy, "mode", "") . ")"
                  : $solar ? "Solar-Automatik (auto_on)" : "";
        if ($other) {
            readingsBeginUpdate($hash);
            readingsBulkUpdate($hash, "clima_state", "aus");
            readingsBulkUpdate($hash, "clima_info",  "übernommen von $other");
            readingsEndUpdate($hash, 1);
            return undef;
        }
        # Notfall, Zeitfenster und Sperre sofort; Energie und erreichte
        # Raumtemperatur erst nach der Mindestlaufzeit
        my $run    = $now - $since;
        my $minRun = $run >= HeatManager_A($name, "hmClimaMinRun") * 60;
        my $why = $notfall                                       ? "Notfall (kein Netz)"
                : !$inWin                                        ? "Zeitfenster vorbei"
                : !$frei                                         ? "Heizgrenze gesperrt"
                : ($minRun && !$eok)                             ? "Energie: $etxt"
                : ($minRun && defined($rtemp) && $rtemp >= $target + 0.5)
                                                                 ? sprintf("Raum %.1f C erreicht", $rtemp)
                :                                                  "";
        if ($why) {
            readingsBeginUpdate($hash);
            readingsBulkUpdate($hash, "clima_state", "aus");
            readingsBulkUpdate($hash, "clima_since", $now);
            readingsBulkUpdate($hash, "clima_info",  "aus: $why");
            readingsEndUpdate($hash, 1);
            HeatManager_Do($hash, "set $dummy autoTemperature aus", "klima", "Klima aus ($why)");
        }
        return undef;
    }

    # --- aus: starten? Alle Hinderungsgründe sammeln (Reading clima_info) ---
    my @no;
    push @no, "Notfall (kein Netz)"   if ($notfall);
    push @no, sprintf("Ventil %.0f %%", $avg)
                                      if (!$full || $avg < HeatManager_A($name, "hmClimaValve"));
    push @no, "Zeitfenster"           if (!$inWin);
    push @no, "Heizgrenze"            if (!$frei);
    push @no, "Klima nicht auf auto"  if (!$auto);
    push @no, "Solar-Automatik aktiv" if ($solar);
    push @no, "Klima laeuft schon"    if ($acOn);
    push @no, $etxt                   if (!$eok);
    push @no, "max. Starts"           if (ReadingsVal($name, "clima_starts_today", 0) >= HeatManager_A($name, "hmClimaMaxStarts"));
    push @no, "Pause"                 if ($now - $since < HeatManager_A($name, "hmClimaMinOff") * 60);
    if (@no) {
        readingsSingleUpdate($hash, "clima_info", "kein Start: " . join(", ", @no), 0);
        return undef;
    }
    my $tset = HeatManager_A($name, "hmClimaSetTemp");
    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "clima_state", "an");
    readingsBulkUpdate($hash, "clima_since", $now);
    readingsBulkUpdate($hash, "clima_starts_today", ReadingsVal($name, "clima_starts_today", 0) + 1);
    readingsBulkUpdate($hash, "clima_info", sprintf("an: %s Ventil %.0f %%, %s", $room, $avg, $etxt));
    readingsEndUpdate($hash, 1);
    HeatManager_Do($hash, "set $dummy autoTemperature $tset", "klima",
                   sprintf("Klima an (%s Ventil %.0f %%, %s)", $room, $avg, $etxt));
    return undef;
}

# ============================================================================
# Schalten, Prüfen, Melden
# ============================================================================

# ----------------------------------------------------------------------------
# HeatManager_Do
#   Einziger Weg, auf dem das Modul schaltet. Simulation: nur Reading
#   sim_<regel> und Log. Sonst Befehl ausführen und optional melden.
# ----------------------------------------------------------------------------
sub HeatManager_Do {
    my ($hash, $cmd, $rule, $msg) = @_;
    my $name = $hash->{NAME};
    if (HeatManager_A($name, "hmSimulate")) {
        readingsBeginUpdate($hash);
        readingsBulkUpdate($hash, "sim_$rule",   $cmd);
        readingsBulkUpdate($hash, "last_action", "SIMULATION: $cmd");
        readingsEndUpdate($hash, 1);
        Log3($name, 3, "HeatManager $name: SIMULATION $cmd");
        return undef;
    }
    my $ret = AnalyzeCommandChain(undef, $cmd);
    Log3($name, 3, "HeatManager $name: $cmd" . ($ret ? " -> $ret" : ""));
    readingsSingleUpdate($hash, "last_action", $cmd . ($ret ? " -> $ret" : ""), 1);
    HeatManager_Notify($hash, $msg) if ($msg);
    return undef;
}

# ----------------------------------------------------------------------------
# HeatManager_VerifyLater
#   SolvisClient setzt Werte über die Bedienoberfläche des Reglers (OCR und
#   Klicks); benutzt jemand die Fernbedienung (HumanAccess), wartet der Server.
#   Deshalb nach 3 min prüfen und bis zu dreimal wiederholen, danach melden.
# ----------------------------------------------------------------------------
sub HeatManager_VerifyLater {
    my ($hash, $heater, $rd, $target, $try) = @_;
    my $name = $hash->{NAME};
    RemoveInternalTimer("verify:$name");
    InternalTimer(gettimeofday() + 180, sub {
        my $v = ReadingsVal($heater, $rd, "");
        if ($v eq $target) {
            readingsSingleUpdate($hash, "verify", "ok ($rd=$target)", 1);
            return;
        }
        if ($try >= 4) {
            readingsSingleUpdate($hash, "verify", "FEHLER: $rd ist $v statt $target", 1);
            HeatManager_Notify($hash, "HeatManager: $rd ist $v statt $target");
            return;
        }
        readingsSingleUpdate($hash, "verify", "Versuch $try: $rd=$v, wiederhole", 1);
        AnalyzeCommandChain(undef, "set $heater $rd $target")
            if (ReadingsVal($heater, "HumanAccess", "none") eq "none");
        HeatManager_VerifyLater($hash, $heater, $rd, $target, $try + 1);
    }, "verify:$name", 0);
    return undef;
}

# ----------------------------------------------------------------------------
# HeatManager_Notify
#   Meldung über hmNotifyCmd (z. B. {send_to_one("michael","N","Heizung","$MSG")}).
# ----------------------------------------------------------------------------
sub HeatManager_Notify {
    my ($hash, $msg) = @_;
    my $cmd = HeatManager_A($hash->{NAME}, "hmNotifyCmd");
    return undef if (!$cmd);
    $cmd =~ s/\$MSG/$msg/g;
    AnalyzeCommandChain(undef, $cmd);
    return undef;
}

# ============================================================================
# set / get
# ============================================================================

# ----------------------------------------------------------------------------
# HeatManager_Set
#   evaluate      - Heizkurven-Auswertung jetzt (in der Simulation ohne Wirkung)
#   clearSamples  - gesammelte Messwerte verwerfen
# ----------------------------------------------------------------------------
sub HeatManager_Set {
    my ($hash, $name, $cmd, @args) = @_;
    return "Unknown argument $cmd, choose one of evaluate:noArg clearSamples:noArg"
        if (!defined($cmd) || $cmd !~ /^(evaluate|clearSamples)$/);
    return HeatManager_Curve($hash, 1) if ($cmd eq "evaluate");
    $hash->{helper}{samples} = [];
    readingsDelete($hash, ".samples");
    readingsSingleUpdate($hash, "state", "Messwerte geloescht", 1);
    return undef;
}

# ----------------------------------------------------------------------------
# HeatManager_Get
#   status - Auswertung und Zustände als Text, ohne etwas zu schalten.
# ----------------------------------------------------------------------------
sub HeatManager_Get {
    my ($hash, $name, $cmd) = @_;
    return "Unknown argument $cmd, choose one of status:noArg"
        if (!defined($cmd) || $cmd ne "status");
    my $e = HeatManager_Evaluate($hash);
    return join("\n",
        "HeatManager v$HM_VERSION" . (HeatManager_A($name, "hmSimulate") ? " (Simulation)" : ""),
        "Messwerte 24h:    $e->{samples} ($e->{samplePct} %)",
        sprintf("Ventile Mittel:   %.1f %%", $e->{valveAvg}),
        "Hoechstes Ventil: " . ($e->{maxRoom} ? sprintf("%s %.0f %%", $e->{maxRoom}, $e->{maxValve}) : "-"),
        "Zu kalt:          " . ($e->{coldRoom} ? "$e->{coldRoom} $e->{coldMin} min" : "-"),
        "Entscheidung:     " . ($e->{step} > 0 ? "+1" : $e->{step} < 0 ? "-1" : "0") . " - $e->{reason}",
        "Ofen:             " . ReadingsVal($name, "oven_state", "?")
            . " (Einsatz " . ReadingsVal($name, "oven_insert", "?")
            . ", Kacheln " . ReadingsVal($name, "oven_tiles", "?") . ")",
        "Klima:            " . ReadingsVal($name, "clima_state", "aus") . " - " . ReadingsVal($name, "clima_info", "-"),
        "Notfall:          " . ReadingsVal($name, "notfall", "off"),
        "Ausgenommen:      " . ReadingsVal($name, "excluded_rooms", "none"));
}

1;

=pod
=item device
=item summary    Heizungsoptimierung: Heizkurve, Standby, Klima und Kachelofen
=item summary_DE Heizungsoptimierung: Heizkurve, Standby, Klima und Kachelofen
=begin html

<a id="HeatManager"></a>
<h3>HeatManager</h3>
<ul>
  Optimiert eine Gasheizung mit Heizkörperthermostaten: passt die Heizkurve
  täglich an die Ventilstellungen an, schaltet den Heizkreis bei geschlossenen
  Ventilen in Standby, lässt ein Klimagerät einen Raum mit dauerhaft offenem
  Ventil stützen und nimmt die Thermostate zurück, solange ein Kachelofen
  heizt. Standard ist die <b>Simulation</b>: es wird nur gerechnet und
  protokolliert (<code>sim_&lt;regel&gt;</code>, <code>last_action</code>).
  <br><br>

  <a id="HeatManager-define"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; HeatManager</code><br>
    Alle Ein- und Ausgänge werden über Attribute zugeordnet.
  </ul><br>

  <a id="HeatManager-set"></a>
  <b>Set</b>
  <ul>
    <li><a id="HeatManager-set-evaluate"></a><b>evaluate</b> &ndash; Heizkurven-Auswertung der letzten 24 h jetzt ausführen (in der Simulation ohne Wirkung)</li>
    <li><a id="HeatManager-set-clearSamples"></a><b>clearSamples</b> &ndash; gesammelte Messwerte verwerfen</li>
  </ul><br>

  <a id="HeatManager-get"></a>
  <b>Get</b>
  <ul>
    <li><a id="HeatManager-get-status"></a><b>status</b> &ndash; Auswertung und Zustände als Text</li>
  </ul><br>

  <a id="HeatManager-attr"></a>
  <b>Attribute</b>
  <ul>
    <li><a id="HeatManager-attr-hmSimulate"></a><b>hmSimulate</b> 1|0 &ndash; Simulation (Default 1)</li>
    <li><a id="HeatManager-attr-hmRules"></a><b>hmRules</b> &ndash; aktive Regeln: curve, standby, klima, ofen</li>
    <li><a id="HeatManager-attr-hmThermostats"></a><b>hmThermostats</b> &ndash; devspec der Thermostate (type=HeatingThermostat)</li>
    <li><a id="HeatManager-attr-hmIgnore"></a><b>hmIgnore</b> &ndash; auszunehmende Thermostate</li>
    <li><a id="HeatManager-attr-hmRoomSensors"></a><b>hmRoomSensors</b> &ndash; Thermostat:Sensor[:Reading], z. B. <code>MAX_040549:Mobil5data</code>; nur diese Räume können als &bdquo;zu kalt&ldquo; gelten</li>
    <li><b>hmHeater</b>, <b>hmFineReading</b>, <b>hmModeReading</b> &ndash; Wärmeerzeuger und dessen Readings</li>
    <li><b>hmFineMin</b>/<b>hmFineMax</b> (-3/2), <b>hmCheckTime</b> (05:00), <b>hmValveLow</b>/<b>hmValveHigh</b> (10/60 %),
        <b>hmColdDelta</b>/<b>hmColdMinutes</b> (0.5 K / 60 min), <b>hmRampIgnore</b> (90 min), <b>hmMinSamplesPct</b> (50 %) &ndash; Regel curve</li>
    <li><b>hmStandbyLow</b>/<b>hmStandbyHigh</b> (1.5/3 %), <b>hmStandbyMinTime</b> (30 min), <b>hmStandbyModeOn</b>/<b>hmStandbyModeOff</b> &ndash; Regel standby</li>
    <li><b>hmOvenSensor</b>, <b>hmOvenTileSensor</b> (Gerät:Reading), <b>hmOvenBurn</b> (60), <b>hmOvenStore</b> (35), <b>hmOvenTemp</b> (17), <b>hmOvenRooms</b> &ndash; Regel ofen</li>
    <li><b>hmClimaRoom</b>, <b>hmClimaDevice</b> (gesetzt wird <code>autoTemperature</code>; <code>auto_on</code> = Solar-Automatik aktiv), <b>hmClimaAc</b>, <b>hmClimaGate</b> (Reading <code>freigabe</code>), <b>hmClimaAffected</b>,
        <b>hmClimaValve</b> (50 %), <b>hmClimaValveMinutes</b> (60), <b>hmClimaTimes</b> (07:00-20:30), <b>hmClimaSetTemp</b> (26),
        <b>hmClimaSoc</b>/<b>hmClimaSocReading</b> (60 %), <b>hmClimaGrid</b> (0 = nur Akku), <b>hmClimaMinOutdoor</b> (3),
        <b>hmClimaMinRun</b>/<b>hmClimaMinOff</b> (60 min), <b>hmClimaMaxStarts</b> (2) &ndash; Regel klima</li>
    <li><a id="HeatManager-attr-hmGridSensor"></a><b>hmGridSensor</b>/<b>hmGridMin</b> (100 V), <b>hmEmergencyReading</b>/<b>hmEmergencyBelow</b> (d_solar:index, -40) &ndash; Notfall: kein Netz am Wechselrichter; die Klima startet nie, ein laufender Lauf des Moduls endet sofort (Reading <code>notfall</code>)</li>
    <li><b>hmOutdoorSensor</b> &ndash; Außentemperatur; <b>hmSampleInterval</b> (300 s); <b>hmNotifyCmd</b> &ndash; Meldungsbefehl, <code>$MSG</code> wird ersetzt; <b>disable</b></li>
  </ul><br>

  <a id="HeatManager-readings"></a>
  <b>Readings</b>
  <ul>
    <li><b>valve_avg_now</b>, <b>valve_avg_24h</b>, <b>valve_max_room</b>, <b>cold_room</b>, <b>samples_24h</b>, <b>ramp_rooms</b>, <b>excluded_rooms</b></li>
    <li><b>fine_current</b>, <b>fine_target</b>, <b>decision</b>, <b>verify</b>, <b>next_check</b></li>
    <li><b>standby_target</b>, <b>standby_since</b>, <b>standby_info</b></li>
    <li><b>oven_state</b> (aus|brennt|speichert), <b>oven_insert</b>, <b>oven_tiles</b>, <b>oven_since</b>, <b>oven_prev_&lt;thermostat&gt;</b></li>
    <li><b>clima_state</b>, <b>clima_info</b>, <b>clima_valve_avg</b>, <b>clima_starts_today</b>, <b>notfall</b></li>
    <li><b>last_action</b>, <b>sim_&lt;regel&gt;</b>; versteckt <b>.samples</b> (Messwerte für den Neustart)</li>
  </ul>
</ul>

=end html
=cut
