#!/usr/bin/perl
#
# Klima v0.8: Abschalten über das Ventil, Anwesenheit, Aufheizphase, Profil.

use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd qw(abs_path);
my $stub = dirname(abs_path(__FILE__)) . "/fhem_stub.pl";
require $stub;
our (%defs, %attr, $NOW, @CMDS);

print "=== Ventil nach Mindestlauf unter 10 % -> aus ===\n";
my $h = setup(hmRules => "klima", hmSimulate => 0, hmRoomSensors => "");
set_rd("MAX_A", "valveposition", 70);
run_samples($h, 13);
ok(rd("clima_state") eq "an", "gestartet");
@CMDS = (); set_rd("MAX_A", "valveposition", 0);
run_samples($h, 6);
ok(!@CMDS, "Ventil zu, aber Mindestlaufzeit -> läuft weiter");
run_samples($h, 7);
ok((grep { $_ eq "set d_clima autoTemperature aus" } @CMDS) ? 1 : 0, "nach Mindestlauf, Ventilmittel < 10 % -> aus");
ok(rd("clima_info") =~ /aus: Ventil \d+ %/, rd("clima_info"));

print "\n=== Anwesenheit ===\n";
$h = setup(hmRules => "klima", hmSimulate => 0);
set_rd("irgendwer", "anwesend", "off");
set_rd("MAX_A", "valveposition", 70); set_rd("SensA", "temperature", 19.5);
run_samples($h, 13);
ok(!@CMDS && rd("clima_info") =~ /niemand zu Hause/, "niemand da -> kein Start: " . rd("clima_info"));
set_rd("irgendwer", "anwesend", "on"); run_samples($h, 1);
ok(rd("clima_state") eq "an", "jemand kommt -> Start");
@CMDS = (); set_rd("irgendwer", "anwesend", "off"); run_samples($h, 1);
ok((grep { /autoTemperature aus/ } @CMDS) && rd("clima_info") =~ /niemand zu Hause/, "alle weg -> sofort aus");
$attr{hm}{hmClimaPresence} = "none"; $NOW += 7200; @CMDS = (); run_samples($h, 13);
ok(rd("clima_state") eq "an", "hmClimaPresence none -> keine Sperre");

print "\n=== Aufheizphase ===\n";
$h = setup(hmRules => "klima", hmSimulate => 0);
set_rd("MAX_A", "valveposition", 70); set_rd("SensA", "temperature", 19.5);
run_samples($h, 2);
set_rd("MAX_A", "desiredTemperature", 21);           # Profilsprung
run_samples($h, 13);
ok(rd("clima_state") ne "an" && rd("clima_info") =~ /Aufheizphase/, "nach Sollwertsprung kein Start: " . rd("clima_info"));
run_samples($h, 6);
ok(rd("clima_state") eq "an", "nach hmRampIgnore (90 min) Start");

print "\n=== Profil senkt innerhalb der Mindestlaufzeit ab ===\n";
$h = setup(hmRules => "klima", hmSimulate => 0);
my @D = qw(Sat Sun Mon Tue Wed Thu Fri);
my @lt = localtime($NOW + 13 * 300); my $m = $lt[2] * 60 + $lt[1] + 30;
my $sp = sprintf("%02d:%02d", int($m / 60), $m % 60); my $idx = ($lt[6] + 1) % 7;
set_rd("MAX_A", "weekprofile-$idx-$D[$idx]-temp", "21 °C  /  19 °C");
set_rd("MAX_A", "weekprofile-$idx-$D[$idx]-time", "00:00-$sp  /  $sp-24:00");
set_rd("MAX_A", "valveposition", 70); set_rd("SensA", "temperature", 19.5);
run_samples($h, 13);
ok(rd("clima_state") ne "an" && rd("clima_info") =~ /Profil senkt bald ab/, "Absenkung in 30 min -> kein Start: " . rd("clima_info"));

done();
