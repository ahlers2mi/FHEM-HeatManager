##############################################################################
# $Id: 98_HeatManager.pm $
# Version:  v0.2.0
#
# HeatManager - Heizungsoptimierung fuer FHEM
#
# Regel "curve":   passt die Heizkurve (Feineinstellung, z. B. SolvisClient
#                  C15.TemperaturFeineinstellung_HK2) einmal taeglich an die
#                  Ventilstellungen der Heizkoerperthermostate an.
# Regel "standby": schaltet den Heizkreis bei fast geschlossenen Ventilen in
#                  Standby - mit Hysterese und Mindestverweildauer.
# Regel "klima":   Klimageraet heizt mit, wenn ein Raumventil lange weit offen
#                  steht (Akku/Netz, Zeitfenster, Start-Begrenzung).
# Regel "ofen":    Kachelofen brennt/speichert -> Thermostate der beheizten
#                  Raeume zuruecknehmen, danach wiederherstellen.
#
# Standard ist der Simulationsmodus (attr hmSimulate 1): das Modul rechnet und
# schreibt Readings, schaltet aber nichts.
#
# Autor: Michael Ahlers, mit Claude
##############################################################################
package main;

use strict;
use warnings;
use Time::Local;

my $HM_VERSION = "0.2.0";

my %HM_defaults = (
  hmThermostats      => "type=HeatingThermostat",
  hmIgnore           => "",
  hmRoomSensors      => "",
  hmHeater           => "mySolvis",
  hmFineReading      => "C15.TemperaturFeineinstellung_HK2",
  hmModeReading      => "C12.Anlagenmodus_HK2",
  hmFineMin          => -3,
  hmFineMax          => 2,
  hmCheckTime        => "05:00",
  hmSampleInterval   => 300,
  hmValveLow         => 10,
  hmValveHigh        => 60,
  hmColdDelta        => 0.5,
  hmColdMinutes      => 60,
  hmRampIgnore       => 90,
  hmMinSamplesPct    => 50,
  hmStandbyLow       => 1.5,
  hmStandbyHigh      => 3,
  hmStandbyMinTime   => 30,
  hmStandbyModeOn    => "Standby",
  hmStandbyModeOff   => "Timer",
  hmSimulate         => 1,
  hmRules            => "curve,standby,klima,ofen",
  hmNotifyCmd        => "",
  hmOutdoorSensor    => "Mobil3data:temperature",
  hmOvenSensor       => "MQTT2_MAX6675_01:Temperatur",
  hmOvenTileSensor   => "XMI_158d00045d0119:temperature",
  hmOvenBurn         => 60,
  hmOvenStore        => 35,
  hmOvenTemp         => 17,
  hmOvenRooms        => "MAX_040549 MAX_0437c3 MAX_06e2ff",
  hmClimaRoom        => "MAX_040549",
  hmClimaDevice      => "d_clima_gaestezimmer",
  hmClimaAc          => "net_ac_86E6",
  hmClimaGate        => "d_klima_heizgrenze",
  hmClimaAffected    => "MAX_0404e5 MAX_040549",
  hmClimaValve       => 50,
  hmClimaValveMinutes => 60,
  hmClimaTimes       => "07:00-20:30",
  hmClimaSetTemp     => 26,
  hmClimaSoc         => 60,
  hmClimaSocReading  => "rem_MQTT2_SMART_SHUNT1:data_state_of_charge_shunt_state",
  hmClimaGrid        => 0,
  hmClimaMinOutdoor  => 3,
  hmClimaMinRun      => 60,
  hmClimaMinOff      => 60,
  hmClimaMaxStarts   => 2,
);

sub HeatManager_Initialize {
  my ($hash) = @_;
  $hash->{DefFn}    = "HeatManager_Define";
  $hash->{UndefFn}  = "HeatManager_Undef";
  $hash->{SetFn}    = "HeatManager_Set";
  $hash->{GetFn}    = "HeatManager_Get";
  $hash->{AttrFn}   = "HeatManager_Attr";
  $hash->{AttrList} = "disable:0,1 hmSimulate:1,0 hmRules:multiple-strict,curve,standby,klima,ofen "
    . "hmThermostats hmIgnore hmRoomSensors:textField-long hmHeater hmFineReading hmModeReading "
    . "hmFineMin hmFineMax hmCheckTime hmSampleInterval hmValveLow hmValveHigh "
    . "hmColdDelta hmColdMinutes hmRampIgnore hmMinSamplesPct "
    . "hmStandbyLow hmStandbyHigh hmStandbyMinTime hmStandbyModeOn hmStandbyModeOff "
    . "hmNotifyCmd:textField-long hmOutdoorSensor "
    . "hmOvenSensor hmOvenTileSensor hmOvenBurn hmOvenStore hmOvenTemp hmOvenRooms "
    . "hmClimaRoom hmClimaDevice hmClimaAc hmClimaGate hmClimaAffected hmClimaValve "
    . "hmClimaValveMinutes hmClimaTimes hmClimaSetTemp hmClimaSoc hmClimaSocReading "
    . "hmClimaGrid:0,1 hmClimaMinOutdoor hmClimaMinRun hmClimaMinOff hmClimaMaxStarts "
    . $readingFnAttributes;
  return;
}

# Attribut mit Modul-Default
sub HeatManager_A {
  my ($name, $a) = @_;
  return AttrVal($name, $a, $HM_defaults{$a});
}

sub HeatManager_RuleOn {
  my ($name, $rule) = @_;
  return (grep { $_ eq $rule } split(/,/, HeatManager_A($name, "hmRules"))) ? 1 : 0;
}

sub HeatManager_Define {
  my ($hash, $def) = @_;
  my @a = split(/\s+/, $def);
  return "Usage: define <name> HeatManager" if (@a != 2);
  my $name = $hash->{NAME};
  $hash->{VERSION}  = $HM_VERSION;
  $hash->{FVERSION} = "98_HeatManager.pm:v$HM_VERSION";
  $hash->{helper}{samples} = [];
  $hash->{helper}{desired} = {};
  readingsSingleUpdate($hash, "state", "initialized", 1);
  RemoveInternalTimer($hash);
  InternalTimer(gettimeofday() + 30, "HeatManager_Sample", $hash, 0);
  HeatManager_ScheduleCheck($hash);
  return;
}

sub HeatManager_Undef {
  my ($hash) = @_;
  RemoveInternalTimer($hash);
  RemoveInternalTimer("check:" . $hash->{NAME});
  RemoveInternalTimer("verify:" . $hash->{NAME});
  return;
}

sub HeatManager_Attr {
  my ($cmd, $name, $attr, $val) = @_;
  my $hash = $defs{$name};
  if ($cmd eq "set" && $attr eq "hmCheckTime") {
    return "hmCheckTime: HH:MM erwartet" if ($val !~ /^\d\d:\d\d$/);
  }
  if ($cmd eq "set" && $attr =~ /^hm(FineMin|FineMax|SampleInterval|ValveLow|ValveHigh|ColdDelta|ColdMinutes|RampIgnore|MinSamplesPct|StandbyLow|StandbyHigh|StandbyMinTime|OvenBurn|OvenStore|OvenTemp|ClimaValve|ClimaValveMinutes|ClimaSetTemp|ClimaSoc|ClimaMinOutdoor|ClimaMinRun|ClimaMinOff|ClimaMaxStarts)$/) {
    return "$attr: Zahl erwartet" if ($val !~ /^-?\d+(\.\d+)?$/);
  }
  if ($attr eq "hmCheckTime" && $init_done && $hash) {
    HeatManager_ScheduleCheck($hash, $cmd eq "set" ? $val : $HM_defaults{hmCheckTime});
  }
  return;
}

# ---------------------------------------------------------------- Sammeln ---

# Liste der Thermostate (devspec minus hmIgnore)
sub HeatManager_Thermostats {
  my ($name) = @_;
  my %ign = map { $_ => 1 } split(/[,\s]+/, HeatManager_A($name, "hmIgnore"));
  return grep { !$ign{$_} && defined($defs{$_}) }
         devspec2array(HeatManager_A($name, "hmThermostats"));
}

# hmRoomSensors: "MAX_040549:Mobil5data MAX_0404d9:Mobil1data:temperature"
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

sub HeatManager_Sample {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my $iv = HeatManager_A($name, "hmSampleInterval");
  $iv = 60 if ($iv < 60);
  InternalTimer(gettimeofday() + $iv, "HeatManager_Sample", $hash, 0);
  return if (IsDisabled($name));

  my $now  = time();
  my $smap = HeatManager_SensorMap($name);
  my $ramp = HeatManager_A($name, "hmRampIgnore") * 60;
  my $cd   = HeatManager_A($name, "hmColdDelta");
  my (%valve, %cold, %ramp, %excl);
  my ($sum, $n) = (0, 0);

  # Ofen und Klima beeinflussen Ventile -> diese Raeume nicht fuer die Heizkurve werten
  my $oven = HeatManager_RuleOn($name, "ofen") ? HeatManager_Oven($hash) : "aus";
  if ($oven ne "aus") { $excl{$_} = "ofen" for split(/[\s,]+/, HeatManager_A($name, "hmOvenRooms")); }
  my $acHeat = ReadingsVal(HeatManager_A($name, "hmClimaAc"), "power", "Off") eq "On"
            && ReadingsVal(HeatManager_A($name, "hmClimaAc"), "mode", "") =~ /heat/i;
  if ($acHeat) { $excl{$_} = "klima" for split(/[\s,]+/, HeatManager_A($name, "hmClimaAffected")); }

  foreach my $t (HeatManager_Thermostats($name)) {
    my $des = ReadingsVal($t, "desiredTemperature", "off");
    my $v   = ReadingsVal($t, "valveposition", undef);
    next if (!defined($v) || $v !~ /^[\d.]+$/);
    # Sprung im Sollwert merken -> Aufheizphase ausblenden
    my $old = $hash->{helper}{desired}{$t};
    if (!defined($old) || $old ne $des) {
      $hash->{helper}{desired}{$t} = $des;
      $hash->{helper}{desiredChange}{$t} = $now if (defined($old));
    }
    $sum += $v; $n++;
    $hash->{helper}{valveNow}{$t} = $v;
    next if ($des !~ /^[\d.]+$/);                       # off/on: keine Bewertung
    next if ($excl{$t});                                # Ofen/Klima
    if (($now - ($hash->{helper}{desiredChange}{$t} // 0)) < $ramp) {
      $ramp{$t} = 1;
      next;
    }
    $valve{$t} = $v;
    if ($smap->{$t}) {
      my $temp = ReadingsVal($smap->{$t}[0], $smap->{$t}[1], undef);
      $cold{$t} = ($temp < $des - $cd) ? 1 : 0
        if (defined($temp) && $temp =~ /^-?[\d.]+$/);
    }
  }
  my $avg = $n ? $sum / $n : 0;

  push @{$hash->{helper}{samples}}, { t => $now, valve => \%valve, cold => \%cold };
  # nur 26 h vorhalten
  @{$hash->{helper}{samples}} = grep { $now - $_->{t} < 26 * 3600 } @{$hash->{helper}{samples}};

  readingsBeginUpdate($hash);
  readingsBulkUpdate($hash, "valve_avg_now", sprintf("%.1f", $avg));
  readingsBulkUpdate($hash, "ramp_rooms", join(",", sort keys %ramp) || "none");
  readingsBulkUpdate($hash, "excluded_rooms", join(",", map { "$_:$excl{$_}" } sort keys %excl) || "none");
  readingsEndUpdate($hash, 1);

  HeatManager_Standby($hash, $avg) if (HeatManager_RuleOn($name, "standby"));
  HeatManager_Clima($hash, $hash->{helper}{valveNow}{HeatManager_A($name, "hmClimaRoom")})
    if (HeatManager_RuleOn($name, "klima"));
  return;
}

# ---------------------------------------------------------------- Standby ---

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

  my $new = $want;
  if ($want ne $on && $avg < HeatManager_A($name, "hmStandbyLow")) {
    $new = $on;
  } elsif ($want eq $on && $avg > HeatManager_A($name, "hmStandbyHigh")) {
    $new = $off;
  }
  return if ($new eq $want);
  if (($now - $since) < $minT) {
    readingsSingleUpdate($hash, "standby_info", "Wechsel nach $new wartet (Mindestzeit)", 1);
    return;
  }
  readingsBeginUpdate($hash);
  readingsBulkUpdate($hash, "standby_target", $new);
  readingsBulkUpdate($hash, "standby_since", $now);
  readingsBulkUpdate($hash, "standby_info", sprintf("%s bei Ventilen %.1f %%", $new, $avg));
  readingsEndUpdate($hash, 1);
  HeatManager_Do($hash, "set $heater $rd $new", "standby");
  return;
}

# ------------------------------------------------------------ Heizkurve ---

sub HeatManager_ScheduleCheck {
  my ($hash, $time) = @_;
  my $name = $hash->{NAME};
  $time //= HeatManager_A($name, "hmCheckTime");
  my ($h, $m) = split(/:/, $time);
  my @lt = localtime(time());
  my $next = timelocal(0, $m, $h, $lt[3], $lt[4], $lt[5]);
  $next += 86400 if ($next <= time() + 5);
  RemoveInternalTimer("check:$name");
  InternalTimer($next, "HeatManager_CheckTimer", "check:$name", 0);
  readingsSingleUpdate($hash, "next_check", FmtDateTime($next), 0);
  return;
}

sub HeatManager_CheckTimer {
  my ($arg) = @_;
  my (undef, $name) = split(/:/, $arg, 2);
  my $hash = $defs{$name};
  return if (!$hash);
  HeatManager_ScheduleCheck($hash);
  HeatManager_Curve($hash) if (!IsDisabled($name) && HeatManager_RuleOn($name, "curve"));
  return;
}

# Auswertung der letzten 24 h, Entscheidung +1 / -1 / 0
sub HeatManager_Evaluate {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my $now  = time();
  my @s = grep { $now - $_->{t} <= 24 * 3600 } @{$hash->{helper}{samples}};
  my $iv = HeatManager_A($name, "hmSampleInterval");
  my $expected = 24 * 3600 / ($iv < 60 ? 60 : $iv);
  my (%vsum, %vn, %cmin);
  foreach my $smp (@s) {
    foreach my $t (keys %{$smp->{valve}}) { $vsum{$t} += $smp->{valve}{$t}; $vn{$t}++; }
    foreach my $t (keys %{$smp->{cold}})  { $cmin{$t} += $smp->{cold}{$t} * $iv / 60; }
  }
  my %vavg = map { $_ => $vsum{$_} / $vn{$_} } keys %vsum;
  my ($all, $cnt) = (0, 0);
  $all += $vavg{$_}, $cnt++ foreach (keys %vavg);
  my $avg = $cnt ? $all / $cnt : 0;
  my ($maxRoom) = sort { $vavg{$b} <=> $vavg{$a} } keys %vavg;
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

sub HeatManager_Curve {
  my ($hash, $manual) = @_;
  my $name   = $hash->{NAME};
  my $heater = HeatManager_A($name, "hmHeater");
  my $rd     = HeatManager_A($name, "hmFineReading");
  my $cur    = ReadingsVal($heater, $rd, undef);
  my $e      = HeatManager_Evaluate($hash);

  my $target = defined($cur) && $cur =~ /^-?\d+$/ ? $cur : undef;
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

# ---------------------------------------------------- Ausfuehren/Pruefen ---

sub HeatManager_Do {
  my ($hash, $cmd, $rule, $msg) = @_;
  my $name = $hash->{NAME};
  if (HeatManager_A($name, "hmSimulate")) {
    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "sim_$rule", $cmd);
    readingsBulkUpdate($hash, "last_action", "SIMULATION: $cmd");
    readingsEndUpdate($hash, 1);
    Log3($name, 3, "$name: SIMULATION $cmd");
    return;
  }
  my $ret = AnalyzeCommandChain(undef, $cmd);
  Log3($name, 3, "$name: $cmd" . ($ret ? " -> $ret" : ""));
  readingsSingleUpdate($hash, "last_action", $cmd . ($ret ? " -> $ret" : ""), 1);
  HeatManager_Notify($hash, $msg) if ($msg);
  return;
}

# SolvisClient setzt Werte ueber die Bedienoberflaeche; bei HumanAccess
# wartet der Server. Deshalb nach 3 min pruefen und notfalls wiederholen.
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
  return;
}

sub HeatManager_Notify {
  my ($hash, $msg) = @_;
  my $cmd = HeatManager_A($hash->{NAME}, "hmNotifyCmd");
  return if (!$cmd);
  $cmd =~ s/\$MSG/$msg/g;
  AnalyzeCommandChain(undef, $cmd);
  return;
}


# ------------------------------------------------------------------- Ofen ---
# Kachelofen: Stahleinsatz > hmOvenBurn -> "brennt", Kacheln > hmOvenStore ->
# "speichert", sonst "aus" (Kachel-Hysterese 2 K). Solange der Ofen brennt oder
# speichert, gehen die Thermostate in hmOvenRooms auf hmOvenTemp; danach wird
# der vorherige Zustand (auto oder Wert) wiederhergestellt.

sub HeatManager_SensorVal {
  my ($spec) = @_;
  my ($d, $r) = split(/:/, $spec // "");
  return undef if (!$d || !$r);
  my $v = ReadingsVal($d, $r, undef);
  return (defined($v) && $v =~ /^(-?[\d.]+)/) ? $1 : undef;
}

sub HeatManager_OvenState {
  my ($hash) = @_;
  my $name  = $hash->{NAME};
  my $ins   = HeatManager_SensorVal(HeatManager_A($name, "hmOvenSensor"));
  my $tile  = HeatManager_SensorVal(HeatManager_A($name, "hmOvenTileSensor"));
  my $old   = ReadingsVal($name, "oven_state", "aus");
  my $store = HeatManager_A($name, "hmOvenStore");
  my $st = "aus";
  if (defined($ins) && $ins > HeatManager_A($name, "hmOvenBurn")) {
    $st = "brennt";
  } elsif (defined($tile) && ($tile > $store || ($old ne "aus" && $tile > $store - 2))) {
    $st = "speichert";
  }
  return ($st, $ins, $tile);
}

sub HeatManager_Oven {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my ($st, $ins, $tile) = HeatManager_OvenState($hash);
  my $old  = ReadingsVal($name, "oven_state", "aus");
  my $otmp = HeatManager_A($name, "hmOvenTemp");
  my $sim  = HeatManager_A($name, "hmSimulate");

  readingsBeginUpdate($hash);
  readingsBulkUpdate($hash, "oven_state", $st);
  readingsBulkUpdate($hash, "oven_insert", $ins // "?");
  readingsBulkUpdate($hash, "oven_tiles", $tile // "?");
  readingsEndUpdate($hash, 1);

  foreach my $t (split(/[\s,]+/, HeatManager_A($name, "hmOvenRooms"))) {
    next if (!$t || !defined($defs{$t}));
    my $prevRd = "oven_prev_$t";
    my $prev   = ReadingsVal($name, $prevRd, "");
    my $des    = ReadingsVal($t, "desiredTemperature", "off");
    if ($st ne "aus") {
      next if ($prev ne "");                                   # schon abgesenkt
      next if ($des !~ /^[\d.]+$/ || $des <= $otmp);           # aus/niedriger: nichts tun
      my $mode = ReadingsVal($t, "mode", "manual") eq "auto" ? "auto" : $des;
      readingsSingleUpdate($hash, $prevRd, $mode, 0);
      HeatManager_Do($hash, "set $t desiredTemperature $otmp", "ofen",
                     "Ofen $st: $t auf $otmp (vorher $mode)");
    } elsif ($prev ne "") {
      # nur zuruecksetzen, wenn der Wert noch unserer ist
      if ($sim || ($des =~ /^[\d.]+$/ && $des == $otmp)) {
        HeatManager_Do($hash, "set $t desiredTemperature $prev", "ofen",
                       "Ofen aus: $t zurueck auf $prev");
      }
      CommandDeleteReading(undef, "$name $prevRd");
    }
  }
  if ($st ne $old) {
    readingsSingleUpdate($hash, "oven_since", FmtDateTime(time()), 1);
    Log3($name, 3, "$name: Ofen $old -> $st");
  }
  return $st;
}

# ------------------------------------------------------------------ Klima ---
# Steht das Ventil von hmClimaRoom im Mittel der letzten hmClimaValveMinutes
# ueber hmClimaValve %, heizt das Klimageraet (ueber dessen Automatik-Dummy)
# mit, statt dass die Heizkurve steigt. Nur im Zeitfenster, mit Freigabe der
# Klima-Heizgrenze, mit genug Akku (oder hmClimaGrid 1), hoechstens
# hmClimaMaxStarts Starts pro Tag und mit Mindestlauf-/Pausenzeiten.

sub HeatManager_InWindow {
  my ($win) = @_;
  my @lt = localtime(time());
  my $now = sprintf("%02d:%02d", $lt[2], $lt[1]);
  foreach my $w (split(/[\s,]+/, $win // "")) {
    my ($a, $b) = split(/-/, $w);
    next if (!$a || !$b);
    return 1 if ($now ge $a && $now lt $b);
  }
  return 0;
}

sub HeatManager_ClimaEnergyOk {
  my ($name, $margin) = @_;
  my $soc = HeatManager_SensorVal(HeatManager_A($name, "hmClimaSocReading"));
  return (1, "Akku $soc %") if (defined($soc) && $soc >= HeatManager_A($name, "hmClimaSoc") - ($margin // 0));
  if (HeatManager_A($name, "hmClimaGrid")) {
    my $out = HeatManager_SensorVal(HeatManager_A($name, "hmOutdoorSensor"));
    return (1, "Netzstrom, aussen $out C")
      if (defined($out) && $out >= HeatManager_A($name, "hmClimaMinOutdoor"));
  }
  return (0, "Akku " . ($soc // "?") . " %");
}

sub HeatManager_Clima {
  my ($hash, $valveNow) = @_;
  my $name  = $hash->{NAME};
  my $room  = HeatManager_A($name, "hmClimaRoom");
  my $dummy = HeatManager_A($name, "hmClimaDevice");
  my $ac    = HeatManager_A($name, "hmClimaAc");
  my $now   = time();
  return if (!$room || !defined($defs{$dummy}));

  # gleitendes Ventilmittel des Raums
  my $win = HeatManager_A($name, "hmClimaValveMinutes") * 60;
  push @{$hash->{helper}{climaValve}}, [$now, $valveNow] if (defined($valveNow));
  @{$hash->{helper}{climaValve}} = grep { $now - $_->[0] <= $win } @{$hash->{helper}{climaValve} // []};
  my @v = map { $_->[1] } @{$hash->{helper}{climaValve}};
  my $avg = @v ? (eval { my $s = 0; $s += $_ for @v; $s }) / @v : 0;
  my $siv  = HeatManager_A($name, "hmSampleInterval");
  my $full = (@v && ($now - $hash->{helper}{climaValve}[0][0]) >= $win - $siv) ? 1 : 0;

  # Tageszaehler
  my @lt = localtime(time());
  my $day = sprintf("%04d-%02d-%02d", $lt[5] + 1900, $lt[4] + 1, $lt[3]);
  if (ReadingsVal($name, "clima_day", "") ne $day) {
    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "clima_day", $day);
    readingsBulkUpdate($hash, "clima_starts_today", 0);
    readingsEndUpdate($hash, 0);
  }

  my $state  = ReadingsVal($name, "clima_state", "aus");          # an = von uns gestartet
  my $since  = ReadingsVal($name, "clima_since", 0);
  my $inWin  = HeatManager_InWindow(HeatManager_A($name, "hmClimaTimes"));
  my $frei   = ReadingsVal(HeatManager_A($name, "hmClimaGate"), "freigabe", "on") eq "on";
  my $auto   = ReadingsVal($dummy, "mode", "") eq "auto";
  my $acOn   = ReadingsVal($ac, "power", "Off") eq "On";
  my ($eok, $etxt) = HeatManager_ClimaEnergyOk($name, $state eq "an" ? 10 : 0);
  my $smap   = HeatManager_SensorMap($name);
  my $rtemp  = $smap->{$room} ? HeatManager_SensorVal("$smap->{$room}[0]:$smap->{$room}[1]") : undef;
  my $target = AttrVal($room, "desiredTemperature", 20);

  readingsSingleUpdate($hash, "clima_valve_avg", sprintf("%.0f", $avg), 0);

  if ($state eq "an") {
    if (!$auto) {   # Nutzer hat uebernommen
      readingsBeginUpdate($hash);
      readingsBulkUpdate($hash, "clima_state", "aus");
      readingsBulkUpdate($hash, "clima_info", "vom Nutzer uebernommen (mode " . ReadingsVal($dummy, "mode", "") . ")");
      readingsEndUpdate($hash, 1);
      return;
    }
    my $run = $now - $since;
    my $why = !$inWin ? "Zeitfenster vorbei"
            : !$frei ? "Heizgrenze gesperrt"
            : ($run >= HeatManager_A($name, "hmClimaMinRun") * 60 && !$eok) ? "Energie: $etxt"
            : ($run >= HeatManager_A($name, "hmClimaMinRun") * 60 && defined($rtemp) && $rtemp >= $target + 0.5)
              ? sprintf("Raum %.1f C erreicht", $rtemp) : "";
    if ($why) {
      readingsBeginUpdate($hash);
      readingsBulkUpdate($hash, "clima_state", "aus");
      readingsBulkUpdate($hash, "clima_since", $now);
      readingsBulkUpdate($hash, "clima_info", "aus: $why");
      readingsEndUpdate($hash, 1);
      HeatManager_Do($hash, "set $dummy autoTemperature aus", "klima", "Klima aus ($why)");
    }
    return;
  }

  # Start pruefen
  my @no;
  push @no, sprintf("Ventil %.0f %%", $avg) if (!$full || $avg < HeatManager_A($name, "hmClimaValve"));
  push @no, "Zeitfenster" if (!$inWin);
  push @no, "Heizgrenze" if (!$frei);
  push @no, "Klima nicht auf auto" if (!$auto);
  push @no, "Klima laeuft schon" if ($acOn);
  push @no, $etxt if (!$eok);
  push @no, "max. Starts" if (ReadingsVal($name, "clima_starts_today", 0) >= HeatManager_A($name, "hmClimaMaxStarts"));
  push @no, "Pause" if ($now - $since < HeatManager_A($name, "hmClimaMinOff") * 60);
  if (@no) {
    readingsSingleUpdate($hash, "clima_info", "kein Start: " . join(", ", @no), 0);
    return;
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
  return;
}

# ------------------------------------------------------------- set / get ---

sub HeatManager_Set {
  my ($hash, $name, $cmd, @args) = @_;
  return "Unknown argument $cmd, choose one of evaluate:noArg clearSamples:noArg"
    if ($cmd !~ /^(evaluate|clearSamples)$/);
  if ($cmd eq "evaluate") {
    return HeatManager_Curve($hash, 1);
  }
  $hash->{helper}{samples} = [];
  readingsSingleUpdate($hash, "state", "Messwerte geloescht", 1);
  return;
}

sub HeatManager_Get {
  my ($hash, $name, $cmd) = @_;
  return "Unknown argument $cmd, choose one of status:noArg" if ($cmd ne "status");
  my $e = HeatManager_Evaluate($hash);
  return join("\n",
    "HeatManager v$HM_VERSION" . (HeatManager_A($name, "hmSimulate") ? " (Simulation)" : ""),
    "Messwerte 24h:   $e->{samples} ($e->{samplePct} %)",
    sprintf("Ventile Mittel: %.1f %%", $e->{valveAvg}),
    "Hoechstes Ventil: " . ($e->{maxRoom} ? sprintf("%s %.0f %%", $e->{maxRoom}, $e->{maxValve}) : "-"),
    "Zu kalt:         " . ($e->{coldRoom} ? "$e->{coldRoom} $e->{coldMin} min" : "-"),
    "Entscheidung:    " . ($e->{step} > 0 ? "+1" : $e->{step} < 0 ? "-1" : "0") . " - $e->{reason}",
    "Ofen:            " . ReadingsVal($name, "oven_state", "?") . " (Einsatz " . ReadingsVal($name, "oven_insert", "?") . ", Kacheln " . ReadingsVal($name, "oven_tiles", "?") . ")",
    "Klima:           " . ReadingsVal($name, "clima_state", "aus") . " - " . ReadingsVal($name, "clima_info", "-"),
    "Ausgenommen:     " . ReadingsVal($name, "excluded_rooms", "none"));
}

1;

=pod
=item helper
=item summary    heating optimisation: heating curve and standby from valve positions
=item summary_DE Heizungsoptimierung: Heizkurve und Standby nach Ventilstellungen
=begin html_DE

<a id="HeatManager"></a>
<h3>HeatManager</h3>
<ul>
  Passt die Heizkurve eines Waermeerzeugers (z. B. SolvisClient) an die
  Ventilstellungen der Heizkoerperthermostate an und schaltet den Heizkreis
  bei fast geschlossenen Ventilen in Standby.<br>
  Standard ist <b>Simulation</b> (<code>attr &lt;name&gt; hmSimulate 1</code>):
  es wird nur gerechnet und protokolliert.<br><br>

  <b>Define</b>: <code>define &lt;name&gt; HeatManager</code><br><br>

  <b>Set</b>
  <ul>
    <li><code>evaluate</code> - Auswertung der letzten 24 h jetzt ausfuehren</li>
    <li><code>clearSamples</code> - gesammelte Messwerte verwerfen</li>
  </ul><br>
  <b>Get</b>
  <ul><li><code>status</code> - aktuelle Auswertung ohne Aktion</li></ul><br>

  <b>Attribute</b>
  <ul>
    <li><code>hmSimulate</code> 1|0 - Simulation (Default 1)</li>
    <li><code>hmRules</code> curve,standby - aktive Regeln</li>
    <li><code>hmThermostats</code> - devspec der Thermostate (Default type=HeatingThermostat)</li>
    <li><code>hmIgnore</code> - auszunehmende Thermostate</li>
    <li><code>hmRoomSensors</code> - Thermostat:Sensor[:Reading], z. B. MAX_040549:Mobil5data</li>
    <li><code>hmHeater</code>, <code>hmFineReading</code>, <code>hmModeReading</code> - Waermeerzeuger und Readings</li>
    <li><code>hmFineMin</code>/<code>hmFineMax</code> - Grenzen der Feineinstellung (-3/2)</li>
    <li><code>hmCheckTime</code> - taegliche Auswertung (05:00)</li>
    <li><code>hmValveLow</code>/<code>hmValveHigh</code> - Ventil-Mittel fuer -1/+1 (10/60 %)</li>
    <li><code>hmColdDelta</code>/<code>hmColdMinutes</code> - Raum gilt als zu kalt (0.5 K, 60 min)</li>
    <li><code>hmRampIgnore</code> - Minuten nach Sollwertsprung ohne Bewertung (90)</li>
    <li><code>hmStandbyLow</code>/<code>hmStandbyHigh</code>/<code>hmStandbyMinTime</code> - Standby-Hysterese (1.5/3 %, 30 min)</li>
    <li><code>hmNotifyCmd</code> - FHEM-Befehl fuer Meldungen, <code>$MSG</code> wird ersetzt</li>
    <li><b>Ofen</b>: <code>hmOvenSensor</code>, <code>hmOvenTileSensor</code> (Geraet:Reading),
        <code>hmOvenBurn</code> (60), <code>hmOvenStore</code> (35), <code>hmOvenTemp</code> (17),
        <code>hmOvenRooms</code> - Thermostate, die zurueckgenommen werden</li>
    <li><b>Klima</b>: <code>hmClimaRoom</code> (Thermostat, dessen Ventil ausloest), <code>hmClimaDevice</code>
        (Automatik-Dummy, gesetzt wird <code>autoTemperature</code>), <code>hmClimaAc</code>, <code>hmClimaGate</code>
        (Reading <code>freigabe</code>), <code>hmClimaAffected</code>, <code>hmClimaValve</code> (50 %),
        <code>hmClimaValveMinutes</code> (60), <code>hmClimaTimes</code> (07:00-20:30), <code>hmClimaSetTemp</code> (26),
        <code>hmClimaSoc</code>/<code>hmClimaSocReading</code> (Akku 60 %), <code>hmClimaGrid</code> (0 = nur Akku),
        <code>hmClimaMinOutdoor</code>, <code>hmClimaMinRun</code>/<code>hmClimaMinOff</code> (60 min), <code>hmClimaMaxStarts</code> (2)</li>
    <li><code>hmOutdoorSensor</code> - Aussentemperatur (Mobil3data:temperature)</li>
  </ul>
</ul>

=end html_DE
=cut
