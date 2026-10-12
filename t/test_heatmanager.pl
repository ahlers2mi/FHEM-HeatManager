#!/usr/bin/perl
# Funktionstest ohne FHEM: Stubs fuer die FHEM-API, dann Szenarien pruefen.
# Aufruf: perl t/test_heatmanager.pl
use strict; use warnings;
our $NOW;
BEGIN { $NOW = 1_800_000_000; *CORE::GLOBAL::time = sub { $main::NOW }; }
use vars qw($readingFnAttributes $init_done %defs %attr); $readingFnAttributes = ""; $init_done = 1;
our (%R, @CMDS);
sub AttrVal { my ($d,$a,$def)=@_; exists $attr{$d}{$a} ? $attr{$d}{$a} : $def }
sub ReadingsVal { my ($d,$r,$def)=@_; exists $R{$d}{$r} ? $R{$d}{$r} : $def }
sub readingsSingleUpdate { my ($h,$r,$v)=@_; $R{$h->{NAME}}{$r}=$v }
sub readingsBeginUpdate {} sub readingsEndUpdate {}
sub readingsBulkUpdate { my ($h,$r,$v)=@_; $R{$h->{NAME}}{$r}=$v }
sub InternalTimer {} sub RemoveInternalTimer {} sub Log3 {}
sub gettimeofday { $NOW } sub FmtDateTime { "ts" } sub IsDisabled { 0 }
sub devspec2array { qw(MAX_A MAX_B MAX_K) }
sub AnalyzeCommandChain { push @CMDS, $_[1]; return undef }
sub CommandDeleteReading { my ($cl,$a)=@_; my ($d,$r)=split(/ /,$a); delete $R{$d}{$r} }
require "./FHEM/98_HeatManager.pm";

my ($ok, $fail) = (0, 0);
sub check($$) { my ($c,$t)=@_; if ($c) { $ok++; print "ok   $t\n" } else { $fail++; print "FAIL $t\n" } }

my $h = { NAME => "hm" }; $defs{hm} = $h; $defs{$_} = { NAME => $_ } for qw(MAX_A MAX_B MAX_K);
HeatManager_Define($h, "hm HeatManager");
$attr{hm}{hmIgnore} = "MAX_K";
$attr{hm}{hmRoomSensors} = "MAX_A:SensA";
$R{mySolvis}{"C15.TemperaturFeineinstellung_HK2"} = 0;
$R{mySolvis}{"C12.Anlagenmodus_HK2"} = "Timer";
$R{mySolvis}{HumanAccess} = "none";

sub day {   # 24 h Messwerte: Ventile A/B, Raum A Temp, Soll
  my ($va, $vb, $ta, $des) = @_;
  $h->{helper}{samples} = [];
  for my $i (1..288) {
    $NOW += 300;
    $R{MAX_A} = { desiredTemperature => $des, valveposition => $va };
    $R{MAX_B} = { desiredTemperature => $des, valveposition => $vb };
    $R{MAX_K} = { desiredTemperature => 15, valveposition => 90 };
    $R{SensA}{temperature} = $ta;
    HeatManager_Sample($h);
  }
}

# 1) Ventile fast zu, warm genug -> -1, Simulation schaltet nicht
@CMDS = (); day(5, 4, 21, 20); HeatManager_Curve($h);
check($R{hm}{fine_target} == -1, "Ventile zu -> Ziel -1");
check(!grep({ /C15/ } @CMDS), "Simulation: kein set C15");
check(($R{hm}{sim_curve} // "") =~ /C15.TemperaturFeineinstellung_HK2 -1/, "sim_curve protokolliert");
check($R{hm}{valve_avg_24h} < 10, "MAX_K (ignoriert) nicht im Mittel");

# 2) Raum zu kalt -> +1
day(30, 20, 19, 20); HeatManager_Curve($h);
check($R{hm}{fine_target} == 1, "Raum A zu kalt -> +1");
check($R{hm}{cold_room} =~ /^MAX_A:/, "cold_room MAX_A");

# 3) Ventil hoch -> +1, Grenze hmFineMax
$R{mySolvis}{"C15.TemperaturFeineinstellung_HK2"} = 2;
day(70, 20, 21, 20); HeatManager_Curve($h);
check($R{hm}{fine_target} == 2 && $R{hm}{decision} =~ /Grenze/, "Grenze hmFineMax");
$R{mySolvis}{"C15.TemperaturFeineinstellung_HK2"} = 0;

# 4) Zielbereich -> 0
day(25, 20, 21, 20); HeatManager_Curve($h);
check($R{hm}{fine_target} == 0, "Zielbereich -> 0");

# 5) Live-Modus setzt wirklich
$attr{hm}{hmSimulate} = 0; @CMDS = ();
day(5, 4, 21, 20); HeatManager_Curve($h);
check(grep({ $_ eq "set mySolvis C15.TemperaturFeineinstellung_HK2 -1" } @CMDS), "Live: set C15 -1");
$attr{hm}{hmSimulate} = 1;

# 6) Aufheizphase nach Sollwertsprung wird ausgeblendet
day(5, 4, 21, 18);
$NOW += 300; $R{MAX_A}{desiredTemperature} = 21; $R{MAX_A}{valveposition} = 100;
HeatManager_Sample($h);
check(!exists $h->{helper}{samples}[-1]{valve}{MAX_A}, "Sprung 18->21: MAX_A ausgeblendet");

# 7) zu wenig Messwerte -> keine Aenderung
$h->{helper}{samples} = [ $h->{helper}{samples}[-1] ];
HeatManager_Curve($h);
check($R{hm}{decision} =~ /zu wenig/, "zu wenig Messwerte");

# 8) Standby-Hysterese mit Mindestzeit
$attr{hm}{hmSimulate} = 0; @CMDS = ();
$R{hm}{standby_since} = 0; delete $R{hm}{standby_target};
HeatManager_Standby($h, 1.0);
check(grep({ /C12.Anlagenmodus_HK2 Standby/ } @CMDS), "1.0 % -> Standby");
@CMDS = (); $NOW += 600; HeatManager_Standby($h, 5);
check(!@CMDS && $R{hm}{standby_info} =~ /Mindestzeit/, "nach 10 min kein Wechsel (Mindestzeit)");
@CMDS = (); $NOW += 1800; HeatManager_Standby($h, 2.5);
check(!@CMDS, "2.5 % (zwischen den Schwellen) -> bleibt Standby");
HeatManager_Standby($h, 3.5);
check(grep({ /C12.Anlagenmodus_HK2 Timer/ } @CMDS), "3.5 % -> Timer");

# 9) Ofen: brennt -> Raum auf 17 (vorher auto), Raum fuer Heizkurve ausgenommen, aus -> zurueck
$attr{hm}{hmRules} = "curve,ofen"; $attr{hm}{hmSimulate} = 0; @CMDS = ();
$attr{hm}{hmOvenRooms} = "MAX_A";
$R{MAX_A} = { desiredTemperature => 20, valveposition => 30, mode => "auto" };
$R{MAX_B} = { desiredTemperature => 20, valveposition => 10 };
$R{MQTT2_MAX6675_01}{Temperatur} = "80.5"; $R{XMI_158d00045d0119}{temperature} = 30;
$NOW += 300; HeatManager_Sample($h);
check($R{hm}{oven_state} eq "brennt", "Ofen 80 C -> brennt");
check(grep({ $_ eq "set MAX_A desiredTemperature 17" } @CMDS), "Ofen: MAX_A auf 17");
check(($R{hm}{oven_prev_MAX_A} // "") eq "auto", "Ofen: vorher auto gemerkt");
check(!exists $h->{helper}{samples}[-1]{valve}{MAX_A}, "Ofen: MAX_A nicht in Heizkurve");
@CMDS = (); $R{MAX_A}{desiredTemperature} = 17; $NOW += 300; HeatManager_Sample($h);
check(!@CMDS, "Ofen: kein zweites Absenken");
$R{MQTT2_MAX6675_01}{Temperatur} = 40; $R{XMI_158d00045d0119}{temperature} = 40;
$NOW += 300; HeatManager_Sample($h);
check($R{hm}{oven_state} eq "speichert", "Einsatz 40, Kacheln 40 -> speichert");
$R{XMI_158d00045d0119}{temperature} = 34; $NOW += 300; HeatManager_Sample($h);
check($R{hm}{oven_state} eq "speichert", "Kacheln 34 (Hysterese) -> speichert");
@CMDS = (); $R{XMI_158d00045d0119}{temperature} = 32; $NOW += 300; HeatManager_Sample($h);
check($R{hm}{oven_state} eq "aus", "Kacheln 32 -> aus");
check(grep({ $_ eq "set MAX_A desiredTemperature auto" } @CMDS), "Ofen aus: MAX_A zurueck auf auto");
check(!exists $R{hm}{oven_prev_MAX_A}, "Ofen: Merker geloescht");
# Nutzer hat waehrenddessen selbst geaendert -> nicht ueberschreiben
$R{MQTT2_MAX6675_01}{Temperatur} = 80; $R{MAX_A}{desiredTemperature} = 20; $NOW += 300; HeatManager_Sample($h);
$R{MAX_A}{desiredTemperature} = 22; $R{MQTT2_MAX6675_01}{Temperatur} = 30; $R{XMI_158d00045d0119}{temperature} = 20;
@CMDS = (); $NOW += 300; HeatManager_Sample($h);
check(!grep({ /MAX_A desiredTemperature/ } @CMDS), "Ofen aus: Nutzerwert 22 bleibt");
$attr{hm}{hmOvenRooms} = "none";

# 10) Klima: Ventil 60 min > 50 %, Akku ok, Fenster -> an; Raum warm -> aus
$defs{d_clima} = { NAME => "d_clima" }; $defs{d_gate} = { NAME => "d_gate" };
$attr{hm}{hmRules} = "klima"; $attr{hm}{hmClimaRoom} = "MAX_A"; $attr{hm}{hmClimaDevice} = "d_clima";
$attr{hm}{hmClimaGate} = "d_gate"; $attr{hm}{hmClimaAc} = "ac"; $attr{hm}{hmClimaSocReading} = "bms:soc";
$attr{hm}{hmClimaTimes} = "00:00-23:59";
$R{d_clima}{mode} = "auto"; $R{ac}{power} = "Off"; $R{d_gate}{freigabe} = "on"; $R{bms}{soc} = 80;
$R{SensA}{temperature} = 19.5; $R{MAX_A} = { desiredTemperature => 20, valveposition => 70 };
$R{hm}{clima_since} = 0; @CMDS = ();
for (1..11) { $NOW += 300; HeatManager_Sample($h); }
check(!@CMDS, "Klima: nach 55 min noch kein Start");
for (1..2) { $NOW += 300; HeatManager_Sample($h); }
check(grep({ $_ eq "set d_clima autoTemperature 26" } @CMDS), "Klima: nach 60 min an");
check($R{hm}{clima_starts_today} == 1, "Klima: Start gezaehlt");
@CMDS = (); $R{SensA}{temperature} = 21; $NOW += 600; HeatManager_Sample($h);
check(!@CMDS, "Klima: Raum warm, aber Mindestlaufzeit -> laeuft weiter");
$NOW += 3600; HeatManager_Sample($h);
check(grep({ $_ eq "set d_clima autoTemperature aus" } @CMDS), "Klima: nach Mindestlauf + Raum warm -> aus");
@CMDS = (); $R{SensA}{temperature} = 19.5; for (1..6) { $NOW += 300; HeatManager_Sample($h); }
check(!@CMDS && $R{hm}{clima_info} =~ /Pause/, "Klima: Pause nach Abschalten");
# Akku leer -> kein Start
$R{bms}{soc} = 30; $NOW += 3600; for (1..13) { $NOW += 300; HeatManager_Sample($h); }
check(!@CMDS && $R{hm}{clima_info} =~ /Akku/, "Klima: Akku 30 % -> kein Start");
$attr{hm}{hmClimaGrid} = 1; $R{Mobil3data}{temperature} = 8; $NOW += 300; HeatManager_Sample($h);
check(grep({ /autoTemperature 26/ } @CMDS), "Klima: hmClimaGrid 1 und 8 C -> an");
# Nutzer stellt manuell -> HeatManager gibt ab
$R{d_clima}{mode} = "manuel"; @CMDS = (); $NOW += 300; HeatManager_Sample($h);
check($R{hm}{clima_state} eq "aus" && !@CMDS, "Klima: Nutzer manuell -> HeatManager gibt ab, kein Befehl");
# Zeitfenster
$R{d_clima}{mode} = "auto"; $attr{hm}{hmClimaTimes} = "00:00-00:01"; $R{hm}{clima_starts_today} = 0;
$NOW += 7200; HeatManager_Sample($h);
check($R{hm}{clima_info} =~ /Zeitfenster/, "Klima: ausserhalb Zeitfenster kein Start");

# 11) Notfall: kein Netz -> laufende Klima sofort aus, kein Start
$attr{hm}{hmClimaTimes} = "00:00-23:59"; $attr{hm}{hmGridSensor} = "wr:netzspannung";
$R{wr}{netzspannung} = "229.5"; $R{bms}{soc} = 90; $R{SensA}{temperature} = 19;
$R{hm}{clima_state} = "an"; $R{hm}{clima_since} = $NOW; @CMDS = ();
$R{wr}{netzspannung} = "0"; $NOW += 300; HeatManager_Sample($h);
check(grep({ $_ eq "set d_clima autoTemperature aus" } @CMDS), "Notfall: laufende Klima sofort aus (vor Mindestlauf)");
check($R{hm}{notfall} eq "on", "Notfall: Reading notfall on");
@CMDS = (); $R{hm}{clima_since} = 0; $R{hm}{clima_starts_today} = 0;
for (1..13) { $NOW += 300; HeatManager_Sample($h); }
check(!@CMDS && $R{hm}{clima_info} =~ /Notfall/, "Notfall: kein Start trotz Ventil/Akku");
$R{wr}{netzspannung} = "230"; $NOW += 300; HeatManager_Sample($h);
check($R{hm}{notfall} eq "off" && grep({ /autoTemperature 26/ } @CMDS), "Netz wieder da: Start moeglich");
delete $R{wr}{netzspannung}; $R{hm}{clima_state} = "aus";

print "\n$ok ok, $fail Fehler\n";
exit($fail ? 1 : 0);
