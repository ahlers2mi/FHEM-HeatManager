#!/usr/bin/perl
#
# Regel klima (Hinweis: nach einer Pause > 60 min braucht das gleitende
# Ventilmittel erst wieder 60 min Messwerte, daher run_samples(..., 13)).
# Start nach Ventilmittel, Mindestlauf/Pause, Akku/Netz,
# Nutzer- und Solar-Übernahme, Zeitfenster, Notfall.

use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd qw(abs_path);
my $stub = dirname(abs_path(__FILE__)) . "/fhem_stub.pl";
require $stub;
our (%defs, %attr, $NOW, @CMDS);

my $h = setup(hmRules => "klima", hmSimulate => 0);
set_rd("MAX_A", "valveposition", 70); set_rd("SensA", "temperature", 19.5);
print "=== Start nach 60 min Ventil > 50 % ===\n";
run_samples($h, 11);
ok(!@CMDS, "nach 55 min noch kein Start (" . rd("clima_info") . ")");
run_samples($h, 2);
ok((grep { $_ eq "set d_clima autoTemperature 26" } @CMDS) ? 1 : 0, "nach 60 min an");
ok(rd("clima_starts_today") == 1, "Start gezählt");

print "\n=== Mindestlauf, dann Raum warm -> aus, Pause ===\n";
@CMDS = (); set_rd("SensA", "temperature", 21); $NOW += 600; HeatManager_Sample($h);
ok(!@CMDS, "Raum warm, aber Mindestlaufzeit -> läuft weiter");
$NOW += 3600; HeatManager_Sample($h);
ok((grep { $_ eq "set d_clima autoTemperature aus" } @CMDS) ? 1 : 0, "nach Mindestlauf + Raum warm -> aus");
@CMDS = (); set_rd("SensA", "temperature", 19.5); run_samples($h, 6);
ok(!@CMDS && rd("clima_info") =~ /Pause/, "Pause nach dem Abschalten");

print "\n=== Akku / Netzstrom ===\n";
set_rd("bms", "soc", 30); $NOW += 3600; run_samples($h, 13);
ok(!@CMDS && rd("clima_info") =~ /Akku/, "Akku 30 % -> kein Start");
$attr{hm}{hmClimaGrid} = 1; run_samples($h, 1);
ok((grep { /autoTemperature 26/ } @CMDS) ? 1 : 0, "hmClimaGrid 1 und 8 C -> an");

print "\n=== Übernahme durch Nutzer oder Solar-Automatik ===\n";
set_rd("d_clima", "mode", "manuel"); @CMDS = (); run_samples($h, 1);
ok(rd("clima_state") eq "aus" && !@CMDS, "Nutzer manuell -> Modul lässt los, kein Befehl");
set_rd("d_clima", "mode", "auto"); $attr{hm}{hmClimaMaxStarts} = 9; $NOW += 7200; run_samples($h, 13);
ok(rd("clima_state") eq "an", "wieder gestartet");
set_rd("d_clima", "auto_on", "on"); @CMDS = (); run_samples($h, 1);
ok(rd("clima_state") eq "aus" && !@CMDS, "Solar-Automatik übernimmt -> Modul lässt los");
$NOW += 7200; run_samples($h, 1);
ok(rd("clima_info") =~ /Solar-Automatik aktiv/, "kein Start, solange auto_on");
set_rd("d_clima", "auto_on", "off");

print "\n=== Zeitfenster ===\n";
$attr{hm}{hmClimaTimes} = "00:00-00:01"; $NOW += 7200; run_samples($h, 1);
ok(rd("clima_info") =~ /Zeitfenster/, "außerhalb des Fensters kein Start");
$attr{hm}{hmClimaTimes} = "00:00-23:59";

print "\n=== Notfall über Netzspannung ===\n";
$attr{hm}{hmClimaGrid} = 0; set_rd("bms", "soc", 90);
$NOW += 7200; run_samples($h, 13);
ok(rd("clima_state") eq "an", "läuft");
set_rd("wr", "netzspannung", "0"); @CMDS = (); run_samples($h, 1);
ok((grep { $_ eq "set d_clima autoTemperature aus" } @CMDS) ? 1 : 0, "Netz weg -> sofort aus (vor Mindestlauf)");
ok(rd("notfall") eq "on", "Reading notfall on");
@CMDS = (); $NOW += 7200; run_samples($h, 13);
ok(!@CMDS && rd("clima_info") =~ /Notfall/, "kein Start im Notfall");
set_rd("wr", "netzspannung", "230"); run_samples($h, 1);
ok(rd("notfall") eq "off" && (grep { /autoTemperature 26/ } @CMDS), "Netz wieder da -> Start möglich");

print "\n=== Notfall über Solarindex (n_d_solar_index <= -40) ===\n";
set_rd("d_solar", "index", -50); @CMDS = (); run_samples($h, 1);
ok(rd("notfall") eq "on" && (grep { /autoTemperature aus/ } @CMDS), "Index -50 -> Notfall, Klima aus");
set_rd("d_solar", "index", 2); run_samples($h, 1);
ok(rd("notfall") eq "off", "Index 2 -> kein Notfall");
done();
