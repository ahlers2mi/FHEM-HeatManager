#!/usr/bin/perl
#
# Regel ofen: Absenken, Merken, Wiederherstellen, Nutzerwert respektieren,
# Ausschluss aus der Heizkurve.

use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd qw(abs_path);
my $stub = dirname(abs_path(__FILE__)) . "/fhem_stub.pl";
require $stub;
our (%defs, %attr, $NOW, @CMDS);

my $h = setup(hmRules => "curve,ofen", hmSimulate => 0, hmOvenRooms => "MAX_A");
set_rd("MAX_A", "mode", "auto");
print "=== Ofen brennt ===\n";
set_rd("ofen", "Temperatur", "80.5");
run_samples($h, 1);
ok(rd("oven_state") eq "brennt", "80,5 C -> brennt");
ok((grep { $_ eq "set MAX_A desiredTemperature 17" } @CMDS) ? 1 : 0, "MAX_A auf 17");
ok(rd("oven_prev_MAX_A") eq "auto", "vorher auto gemerkt");
ok(!exists $h->{helper}{samples}[-1]{valve}{MAX_A}, "MAX_A nicht in der Heizkurve");
ok(rd("excluded_rooms") eq "MAX_A:ofen", "excluded_rooms " . rd("excluded_rooms"));
@CMDS = (); run_samples($h, 1);
ok(!@CMDS, "kein zweites Absenken");

print "\n=== Ofen speichert, Hysterese, aus ===\n";
set_rd("ofen", "Temperatur", 40); set_rd("kachel", "temperature", 40); run_samples($h, 1);
ok(rd("oven_state") eq "speichert", "Kacheln 40 -> speichert");
set_rd("kachel", "temperature", 34); run_samples($h, 1);
ok(rd("oven_state") eq "speichert", "Kacheln 34 (Hysterese) -> speichert");
@CMDS = (); set_rd("kachel", "temperature", 32); run_samples($h, 1);
ok(rd("oven_state") eq "aus", "Kacheln 32 -> aus");
ok((grep { $_ eq "set MAX_A desiredTemperature auto" } @CMDS) ? 1 : 0, "MAX_A zurück auf auto");
ok(rd("oven_prev_MAX_A") eq "", "Merker gelöscht");

print "\n=== Nutzer stellt während des Ofens selbst um ===\n";
set_rd("ofen", "Temperatur", 80); set_rd("MAX_A", "desiredTemperature", 20); run_samples($h, 1);
set_rd("MAX_A", "desiredTemperature", 22); set_rd("ofen", "Temperatur", 30); set_rd("kachel", "temperature", 20);
@CMDS = (); run_samples($h, 1);
ok(!grep({ /MAX_A desiredTemperature/ } @CMDS), "Nutzerwert 22 bleibt");

print "\n=== Thermostat aus oder niedriger -> unberührt ===\n";
set_rd("MAX_A", "desiredTemperature", "off"); set_rd("ofen", "Temperatur", 80);
@CMDS = (); run_samples($h, 1);
ok(!@CMDS && rd("oven_prev_MAX_A") eq "", "off bleibt off, nichts gemerkt");
done();
