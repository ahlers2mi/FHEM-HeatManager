##############################################################################
# $Id: 98_HeatManager.pm $
# Version:  v0.1.0
#
# HeatManager - Heizungsoptimierung fuer FHEM
#
# Regel "curve":   passt die Heizkurve (Feineinstellung, z. B. SolvisClient
#                  C15.TemperaturFeineinstellung_HK2) einmal taeglich an die
#                  Ventilstellungen der Heizkoerperthermostate an.
# Regel "standby": schaltet den Heizkreis bei fast geschlossenen Ventilen in
#                  Standby - mit Hysterese und Mindestverweildauer.
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

my $HM_VERSION = "0.1.0";

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
  hmRules            => "curve,standby",
  hmNotifyCmd        => "",
);

sub HeatManager_Initialize {
  my ($hash) = @_;
  $hash->{DefFn}    = "HeatManager_Define";
  $hash->{UndefFn}  = "HeatManager_Undef";
  $hash->{SetFn}    = "HeatManager_Set";
  $hash->{GetFn}    = "HeatManager_Get";
  $hash->{AttrFn}   = "HeatManager_Attr";
  $hash->{AttrList} = "disable:0,1 hmSimulate:1,0 hmRules:multiple-strict,curve,standby "
    . "hmThermostats hmIgnore hmRoomSensors:textField-long hmHeater hmFineReading hmModeReading "
    . "hmFineMin hmFineMax hmCheckTime hmSampleInterval hmValveLow hmValveHigh "
    . "hmColdDelta hmColdMinutes hmRampIgnore hmMinSamplesPct "
    . "hmStandbyLow hmStandbyHigh hmStandbyMinTime hmStandbyModeOn hmStandbyModeOff "
    . "hmNotifyCmd:textField-long "
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
  if ($cmd eq "set" && $attr =~ /^hm(FineMin|FineMax|SampleInterval|ValveLow|ValveHigh|ColdDelta|ColdMinutes|RampIgnore|MinSamplesPct|StandbyLow|StandbyHigh|StandbyMinTime)$/) {
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
  my (%valve, %cold, %ramp);
  my ($sum, $n) = (0, 0);

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
    next if ($des !~ /^[\d.]+$/);                       # off/on: keine Bewertung
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
  readingsEndUpdate($hash, 1);

  HeatManager_Standby($hash, $avg) if (HeatManager_RuleOn($name, "standby"));
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
  my @lt = localtime();
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
    "Entscheidung:    " . ($e->{step} > 0 ? "+1" : $e->{step} < 0 ? "-1" : "0") . " - $e->{reason}");
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
  </ul>
</ul>

=end html_DE
=cut
