#!/usr/bin/perl
#
# Regel rampe: Zwischenwert vor einem Profilsprung nach oben.

use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd qw(abs_path);
my $stub = dirname(abs_path(__FILE__)) . "/fhem_stub.pl";
require $stub;
our (%defs, %attr, $NOW, @CMDS);

my @D = qw(Sat Sun Mon Tue Wed Thu Fri);
# Profil so legen, dass der Sprung $vor Minuten nach "jetzt" liegt
sub profil {
    my ($t, $vor, $lo, $hi) = @_;
    my @lt  = localtime($NOW);
    my $m   = $lt[2] * 60 + $lt[1] + $vor;
    my $sp  = sprintf("%02d:%02d", int($m / 60), $m % 60);
    my $idx = ($lt[6] + 1) % 7;
    set_rd($t, "weekprofile-$idx-$D[$idx]-temp", "$lo °C  /  $hi °C  /  $lo °C");
    set_rd($t, "weekprofile-$idx-$D[$idx]-time", "00:00-$sp  /  $sp-22:00  /  22:00-24:00");
    set_rd($t, "mode", "auto");
    set_rd($t, "desiredTemperature", $lo);
}

print "=== Sprung 19 -> 21 in 25 min: Zwischenwert 20 (Simulation) ===\n";
my $h = setup(hmRules => "rampe");
profil("MAX_A", 25, 19, 21); profil("MAX_B", 25, 19, 21);
HeatManager_Rampe($h, {});
ok(rd("sim_rampe") =~ /set MAX_A desiredTemperature auto 20\.0/, "sim_rampe: " . rd("sim_rampe"));
ok(!grep({ /desiredTemperature/ } @CMDS), "Simulation schaltet nicht");
ok(rd("rampe_info") =~ /MAX_A 19\.0 -> 20\.0 \(Profil 21\.0/, "rampe_info: " . rd("rampe_info"));
ok(scalar(@{$h->{helper}{rampQueue}}) == 1, "MAX_B wartet 15 s in der Schlange");
HeatManager_RampeQueue($h);
ok(rd("sim_rampe") =~ /MAX_B/, "danach MAX_B");

print "\n=== nur einmal je Schaltpunkt ===\n";
$h->{READINGS}{sim_rampe}{VAL} = "";
HeatManager_Rampe($h, {});
ok(rd("sim_rampe") eq "", "kein zweites Mal");

print "\n=== Live: echter Befehl ===\n";
$h = setup(hmRules => "rampe", hmSimulate => 0, hmRampRooms => "MAX_A");
profil("MAX_A", 10, 19, 20.5);
HeatManager_Rampe($h, {});
ok((grep { $_ eq "set MAX_A desiredTemperature auto 20.0" } @CMDS) ? 1 : 0, "19 -> 20.5: auto 20.0 gesendet");

print "\n=== keine Rampe ===\n";
$h = setup(hmRules => "rampe", hmSimulate => 0);
profil("MAX_A", 45, 19, 21);                       # zu weit weg
profil("MAX_B", 20, 19, 20);                       # Sprung nur 1 K
HeatManager_Rampe($h, {});
ok(!@CMDS, "45 min vorher und 1-K-Sprung -> nichts");
$h = setup(hmRules => "rampe", hmSimulate => 0);
profil("MAX_A", 20, 19, 21); set_rd("MAX_A", "mode", "manual");
profil("MAX_B", 20, 19, 21); set_rd("MAX_B", "desiredTemperature", 17);
HeatManager_Rampe($h, {});
ok(!@CMDS, "manual bzw. von Hand/Abwesenheit verstellt -> nichts");
$h = setup(hmRules => "rampe", hmSimulate => 0);
profil("MAX_A", 20, 21, 19);
HeatManager_Rampe($h, { MAX_B => "klima" }); profil("MAX_B", 20, 19, 21);
HeatManager_Rampe($h, { MAX_B => "klima" });
ok(!@CMDS, "Sprung nach unten bzw. Raum von Klima/Ofen ausgenommen -> nichts");
$h = setup(hmRules => "rampe", hmSimulate => 0);
HeatManager_Rampe($h, {});
ok(!@CMDS, "ohne Profil-Readings -> nichts, kein Fehler");

print "\n=== über die Messung (SampleRun) ===\n";
$h = setup(hmRules => "rampe", hmSimulate => 0, hmRampRooms => "MAX_A");
profil("MAX_A", 22, 19, 21);
run_samples($h, 1);
ok((grep { /MAX_A desiredTemperature auto 20\.0/ } @CMDS) ? 1 : 0, "Messung löst Rampe aus");

done();
