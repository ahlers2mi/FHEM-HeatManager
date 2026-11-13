#!/usr/bin/perl
#
# hmHandDelta (v0.11.0): von Hand über das Wochenprofil gedrehte Räume zählen
# weder als "zu kalt" noch für das Ventilmittel (curve, tag).

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

print "=== ohne hmHandDelta (0): Bad auf 25 gedreht, erreicht 21 -> +1 ===\n";
my $h = setup(hmRules => "curve", hmHandDelta => 0);
tag24($h, 25, 21, 80);
HeatManager_Curve($h);
ok(rd("fine_target") == 1 && rd("cold_room") =~ /^MAX_A:/, "bisheriges Verhalten: Ziel +1, " . rd("decision"));

print "\n=== Standard (0.5): derselbe Tag -> Raum ausgeblendet, kein +1 ===\n";
$h = setup(hmRules => "curve");
tag24($h, 25, 21, 80);
ok(rd("excluded_rooms") eq "MAX_A:hand", "excluded_rooms " . rd("excluded_rooms"));
HeatManager_Curve($h);
ok(rd("fine_target") == 0 && rd("cold_room") eq "none", "Ziel 0, cold_room none (" . rd("decision") . ")");

print "\n=== Soll = Profil, Raum zu kalt -> zählt weiter ===\n";
$h = setup(hmRules => "curve");
tag24($h, 20, 19, 30);
HeatManager_Curve($h);
ok(rd("fine_target") == 1 && rd("excluded_rooms") eq "none", "Ziel +1, nichts ausgeblendet");

print "\n=== knapp über Profil (0.5 K) zählt noch, boost nicht ===\n";
$h = setup(hmRules => "curve");
profil("MAX_A", 20); set_rd("MAX_A", "desiredTemperature", 20.5);
ok(!HeatManager_HandHigh("hm", "MAX_A", 20.5), "20.5 bei Profil 20: kein hand");
ok(HeatManager_HandHigh("hm", "MAX_A", 21), "21 bei Profil 20: hand");
set_rd("MAX_A", "mode", "boost");
ok(HeatManager_HandHigh("hm", "MAX_A", 20), "boost: hand");
set_rd("MAX_B", "mode", "manual");
ok(!HeatManager_HandHigh("hm", "MAX_B", 25), "ohne Profil: keine Bewertung");

print "\n=== Zwischenwert der Rampe gilt nicht als hand ===\n";
{
    my @lt  = localtime($NOW);
    my $m   = $lt[2] * 60 + $lt[1] + 20;
    my $sp  = sprintf("%02d:%02d", int($m / 60), $m % 60);
    my $idx = ($lt[6] + 1) % 7;
    set_rd("MAX_A", "weekprofile-$idx-$D[$idx]-temp", "19 °C  /  21 °C");
    set_rd("MAX_A", "weekprofile-$idx-$D[$idx]-time", "00:00-$sp  /  $sp-24:00");
    set_rd("MAX_A", "mode", "auto");
    ok(!HeatManager_HandHigh("hm", "MAX_A", 20), "Profil 19, in 20 min 21, Soll 20: kein hand");
    ok(HeatManager_HandHigh("hm", "MAX_A", 22), "Soll 22 darüber: hand");
}

print "\n=== Regel tag sieht den Raum nicht ===\n";
$h = setup(hmRules => "tag", hmDayTimes => "00:00-23:59", hmLive => "tag", hmDayColdRooms => 1);
profil("MAX_A", 20); profil("MAX_B", 20);
set_rd("MAX_A", "desiredTemperature", 25); set_rd("MAX_A", "valveposition", 90);
set_rd("MAX_B", "desiredTemperature", 20); set_rd("MAX_B", "valveposition", 90);
set_rd("SensA", "temperature", 21); set_rd("MAX_B", "temperature", 20.0);
run_samples($h, 25);
ok(!grep({ /C15/ } @CMDS) && rd("day_cold") eq "none", "kein +1, day_cold " . rd("day_cold") . ", " . rd("day_info"));

done();
