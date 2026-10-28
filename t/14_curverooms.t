#!/usr/bin/perl
#
# hmCurveRooms (v0.9.0): nur ausgewählte Räume zählen für das Ventilmittel.

use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd qw(abs_path);
my $stub = dirname(abs_path(__FILE__)) . "/fhem_stub.pl";
require $stub;
our (%defs, %attr, $NOW, @CMDS);

print "=== ohne hmCurveRooms: kühler Raum drückt das Mittel -> -1 ===\n";
my $h = setup(hmRules => "curve");
day($h, 15, 0, 21, 20);                     # A 15 %, B (kühl) 0 %, A warm
my $e = HeatManager_Evaluate($h);
ok($e->{step} == -1, "($e->{reason}) Mittel " . sprintf("%.1f", $e->{valveAvg}) . " -> step $e->{step}");

print "\n=== mit hmCurveRooms MAX_A: nur A zählt -> Zielbereich ===\n";
$h = setup(hmRules => "curve", hmCurveRooms => "MAX_A");
day($h, 15, 0, 21, 20);
$e = HeatManager_Evaluate($h);
ok($e->{step} == 0 && abs($e->{valveAvg} - 15) < 0.01, "Mittel " . sprintf("%.1f", $e->{valveAvg}) . " -> step $e->{step}");

print "\n=== höchstes Ventil sieht weiter alle Räume ===\n";
$h = setup(hmRules => "curve", hmCurveRooms => "MAX_A");
day($h, 15, 70, 21, 20);
$e = HeatManager_Evaluate($h);
ok($e->{step} == 1 && $e->{maxRoom} eq "MAX_B", "MAX_B 70 % -> +1 ($e->{reason})");

print "\n=== Regel tag nutzt dieselbe Auswahl ===\n";
$h = setup(hmRules => "tag", hmDayTimes => "00:00-23:59", hmLive => "tag", hmCurveRooms => "MAX_A",
           hmRoomSensors => "MAX_A:SensA");
set_rd("MAX_A", "desiredTemperature", 21); set_rd("MAX_A", "valveposition", 40);
set_rd("MAX_B", "desiredTemperature", 21); set_rd("MAX_B", "valveposition", 90);
set_rd("SensA", "temperature", 19.9); set_rd("MAX_B", "temperature", 20.0);
run_samples($h, 25);
ok(!grep({ /C15/ } @CMDS) && rd("day_info") =~ /ok, Ventile 40 %/, "nur A (40 %) zählt: " . rd("day_info"));

done();
