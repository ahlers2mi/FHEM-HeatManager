#!/usr/bin/perl
#
# Regel klima: Abschalten nach dem aktuellen Sollwert des Thermostats
# (Reading desiredTemperature), nicht nur nach dem Attribut.

use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd qw(abs_path);
my $stub = dirname(abs_path(__FILE__)) . "/fhem_stub.pl";
require $stub;
our (%defs, %attr, $NOW, @CMDS);

print "=== HeatManager_RoomTarget ===\n";
setup();
set_rd("MAX_A", "desiredTemperature", "21.0");
ok(HeatManager_RoomTarget("MAX_A") == 21, "Reading 21.0 -> 21");
set_rd("MAX_A", "desiredTemperature", "off"); $attr{MAX_A}{desiredTemperature} = 19;
ok(HeatManager_RoomTarget("MAX_A") == 19, "Reading off -> Attribut 19");
delete $attr{MAX_A};
ok(HeatManager_RoomTarget("MAX_A") == 20, "weder Reading noch Attribut -> 20");

print "\n=== Klima läuft bis Profil-Soll + 0.5 ===\n";
my $h = setup(hmRules => "klima", hmSimulate => 0);
set_rd("MAX_A", "desiredTemperature", "21.0");
set_rd("MAX_A", "valveposition", 70); set_rd("SensA", "temperature", 19.5);
run_samples($h, 13);
ok(rd("clima_state") eq "an", "gestartet");
@CMDS = (); set_rd("SensA", "temperature", 20.6); $NOW += 3900; HeatManager_Sample($h);
ok(rd("clima_state") eq "an" && !@CMDS, "20.6 C bei Soll 21 -> läuft weiter (bis v0.6.1: aus)");
set_rd("SensA", "temperature", 21.5); $NOW += 300; HeatManager_Sample($h);
ok((grep { $_ eq "set d_clima autoTemperature aus" } @CMDS) ? 1 : 0, "21.5 C -> aus");

done();
