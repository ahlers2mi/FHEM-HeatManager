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

print "\n$ok ok, $fail Fehler\n";
exit($fail ? 1 : 0);
