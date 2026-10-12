#!/usr/bin/perl
#
# Regel curve: tägliche Auswertung der Ventile und Raumtemperaturen,
# Grenzen, Aufheizphasen, Simulation vs. Live, Restore nach Neustart.

use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd qw(abs_path);
my $stub = dirname(abs_path(__FILE__)) . "/fhem_stub.pl";
require $stub;
our (%defs, %attr, $NOW, @CMDS);
my $h;

print "=== Ventile fast zu, Raum warm -> -1 (Simulation schaltet nicht) ===\n";
$h = setup(hmRules => "curve");
day($h, 5, 4, 21, 20); HeatManager_Curve($h);
ok(rd("fine_target") == -1, "Ziel -1 (" . rd("decision") . ")");
ok(!grep({ /C15/ } @CMDS), "kein set C15 in der Simulation");
ok(rd("sim_curve") =~ /C15.TemperaturFeineinstellung_HK2 -1/, "sim_curve protokolliert");
ok(rd("valve_avg_24h") < 10, "Keller (hmIgnore, Ventil 90) nicht im Mittel");

print "\n=== Raum zu kalt -> +1 ===\n";
day($h, 30, 20, 19, 20); HeatManager_Curve($h);
ok(rd("fine_target") == 1, "Ziel +1");
ok(rd("cold_room") =~ /^MAX_A:/, "cold_room " . rd("cold_room"));

print "\n=== Ventil dauerhaft weit offen, Grenze hmFineMax ===\n";
set_rd("mySolvis", "C15.TemperaturFeineinstellung_HK2", 2);
day($h, 70, 20, 21, 20); HeatManager_Curve($h);
ok(rd("fine_target") == 2 && rd("decision") =~ /Grenze/, "bleibt 2: " . rd("decision"));
set_rd("mySolvis", "C15.TemperaturFeineinstellung_HK2", 0);

print "\n=== Zielbereich -> 0 ===\n";
day($h, 25, 20, 21, 20); HeatManager_Curve($h);
ok(rd("fine_target") == 0, "Ziel 0");

print "\n=== Live: set C15 ===\n";
$attr{hm}{hmSimulate} = 0; @CMDS = ();
day($h, 5, 4, 21, 20); HeatManager_Curve($h);
ok((grep { $_ eq "set mySolvis C15.TemperaturFeineinstellung_HK2 -1" } @CMDS) ? 1 : 0, "set mySolvis C15 -1");
$attr{hm}{hmSimulate} = 1;

print "\n=== Sollwertsprung: Aufheizphase ausgeblendet ===\n";
day($h, 5, 4, 21, 18);
$NOW += 300; set_rd("MAX_A", "desiredTemperature", 21); set_rd("MAX_A", "valveposition", 100);
HeatManager_Sample($h);
ok(!exists $h->{helper}{samples}[-1]{valve}{MAX_A}, "MAX_A nach 18->21 nicht gewertet");
ok(rd("ramp_rooms") eq "MAX_A", "ramp_rooms MAX_A");

print "\n=== zu wenig Messwerte ===\n";
$h->{helper}{samples} = [ $h->{helper}{samples}[-1] ];
HeatManager_Curve($h);
ok(rd("decision") =~ /zu wenig/, rd("decision"));

print "\n=== Restore nach Neustart ===\n";
$h = setup(hmRules => "curve");
day($h, 5, 4, 21, 20);
ok(rd(".samples") ne "", ".samples geschrieben");
my $saved = rd(".samples");
my $h2 = { NAME => "hm", TYPE => "HeatManager", READINGS => { ".samples" => { VAL => $saved } } };
$defs{hm} = $h2;
HeatManager_Define($h2, "hm HeatManager");
HeatManager_restoreState($h2);
ok(@{$h2->{helper}{samples}} > 250, scalar(@{$h2->{helper}{samples}}) . " Messwerte übernommen");
HeatManager_Curve($h2);
ok(rd("fine_target") == -1, "Auswertung direkt nach Neustart möglich (" . rd("decision") . ")");

done();
