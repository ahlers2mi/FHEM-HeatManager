#!/usr/bin/perl
#
# hmColdValve (v0.12.0): "zu kalt" zählt für die Heizkurve nur, wenn das Ventil
# des Raums weit offen ist - sonst regelt das Thermostat selbst ab.

use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd qw(abs_path);
my $stub = dirname(abs_path(__FILE__)) . "/fhem_stub.pl";
require $stub;
our (%defs, %attr, $NOW, @CMDS);

my @D = qw(Sat Sun Mon Tue Wed Thu Fri);
# ganztägiges Profil mit einem Wert
sub profil {
    my ($t, $temp) = @_;
    my $idx = ((localtime($NOW))[6] + 1) % 7;
    set_rd($t, "weekprofile-$idx-$D[$idx]-temp", "$temp °C");
    set_rd($t, "weekprofile-$idx-$D[$idx]-time", "00:00-24:00");
    set_rd($t, "mode", "auto");
}
# 24 h: A mit Raumsensor, Soll $des, Raum $ta, Ventil $va; B normal
sub tag24 {
    my ($h, $des, $ta, $va) = @_;
    $h->{helper}{samples} = [];
    run_samples($h, 288, sub {
        profil("MAX_A", 20); profil("MAX_B", 20);
        set_rd("MAX_A", "desiredTemperature", $des); set_rd("MAX_A", "valveposition", $va);
        set_rd("MAX_B", "desiredTemperature", 20);   set_rd("MAX_B", "valveposition", 20);
        set_rd("SensA", "temperature", $ta);
    });
}

print "=== Standard (80 %): Raum unter Soll, Ventil fast zu -> kein +1 ===\n";
my $h = setup(hmRules => "curve");
tag24($h, 19, 18.4, 15);
HeatManager_Curve($h);
ok(rd("fine_target") == 0 && rd("cold_room") eq "none", "Ziel 0, cold_room none (" . rd("decision") . ")");

print "\n=== Ventil knapp unter der Schwelle (79 %) zählt nicht, 80 % zählt ===\n";
$h = setup(hmRules => "curve", hmValveHigh => 100);
tag24($h, 19, 18.4, 79);
HeatManager_Curve($h);
ok(rd("fine_target") == 0 && rd("cold_room") eq "none", "79 %: Ziel 0 (" . rd("decision") . ")");
$h = setup(hmRules => "curve", hmValveHigh => 100);
tag24($h, 19, 18.4, 80);
HeatManager_Curve($h);
ok(rd("fine_target") == 1 && rd("cold_room") =~ /^MAX_A:/, "80 %: Ziel +1 (" . rd("decision") . ")");

print "\n=== hmColdValve 0: altes Verhalten, zählt immer ===\n";
$h = setup(hmRules => "curve", hmColdValve => 0);
tag24($h, 19, 18.4, 15);
HeatManager_Curve($h);
ok(rd("fine_target") == 1 && rd("cold_room") =~ /^MAX_A:/, "Ziel +1 (" . rd("decision") . ")");

print "\n=== eigene Schwelle 50 % ===\n";
$h = setup(hmRules => "curve", hmColdValve => 50, hmValveHigh => 100);
tag24($h, 19, 18.4, 55);
HeatManager_Curve($h);
ok(rd("fine_target") == 1, "55 % bei Schwelle 50: Ziel +1");

done();
