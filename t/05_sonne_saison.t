#!/usr/bin/perl
#
# Regeln sonne (Absenkung im Sonnenfenster nach PV-Prognose) und saison
# (Heizbeginn/-ende nach DWD-Prognose).

use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd qw(abs_path);
use POSIX qw(mktime);
my $stub = dirname(abs_path(__FILE__)) . "/fhem_stub.pl";
require $stub;
our (%defs, %attr, $NOW, @CMDS);

# Uhrzeit HH:MM am Testtag als Epoch (lokale Zeit)
sub at_time {
    my ($hm, $dayOffset) = @_;
    my ($H, $M) = split(/:/, $hm);
    my @t = CORE::localtime(1_800_000_000);
    return POSIX::mktime(0, $M, $H, $t[3] + ($dayOffset // 0), $t[4], $t[5]);
}
sub pv { my ($wh) = @_; set_rd("Forecast", sprintf("Today_Hour%02d_PVforecast", $_), $wh) for 10 .. 15; }

print "=== Sonnig: 09-15 Uhr eine Stufe runter, danach zurück ===\n";
my $h = setup(hmRules => "sonne", hmSimulate => 0, hmSunTempReading => "dwd:fc0_12_TTT");
pv(2000); set_rd("dwd", "fc0_12_TTT", 8);
$NOW = at_time("05:30"); HeatManager_Sample($h);
ok(rd("sun_planned") eq "", "vor hmSunCheckTime kein Plan");
$NOW = at_time("06:05"); HeatManager_Sample($h);
ok(rd("sun_planned") eq "ja", "Plan: " . rd("sun_forecast"));
ok(!@CMDS, "vor dem Fenster nichts geschaltet");
$NOW = at_time("09:05"); HeatManager_Sample($h);
ok((grep { $_ eq "set mySolvis C15.TemperaturFeineinstellung_HK2 -1" } @CMDS) ? 1 : 0, "09:05 -> C15 -1");
ok(rd("sun_base") eq "0", "Ausgangswert 0 gemerkt");
@CMDS = (); $NOW = at_time("12:00"); HeatManager_Sample($h);
ok(!@CMDS, "im Fenster kein weiterer Befehl");
$NOW = at_time("15:05"); HeatManager_Sample($h);
ok((grep { $_ eq "set mySolvis C15.TemperaturFeineinstellung_HK2 0" } @CMDS) ? 1 : 0, "15:05 -> zurück auf 0");
ok(rd("sun_active") eq "off", "sun_active off");

print "\n=== Trüb oder kalt: keine Absenkung ===\n";
$h = setup(hmRules => "sonne", hmSimulate => 0, hmSunTempReading => "dwd:fc0_12_TTT");
pv(500); set_rd("dwd", "fc0_12_TTT", 8);
$NOW = at_time("06:05"); HeatManager_Sample($h); $NOW = at_time("10:00"); HeatManager_Sample($h);
ok(rd("sun_planned") eq "nein" && !@CMDS, "3 kWh: kein Plan (" . rd("sun_forecast") . ")");
$h = setup(hmRules => "sonne", hmSimulate => 0, hmSunTempReading => "dwd:fc0_12_TTT");
pv(2000); set_rd("dwd", "fc0_12_TTT", -2);
$NOW = at_time("06:05"); HeatManager_Sample($h); $NOW = at_time("10:00"); HeatManager_Sample($h);
ok(rd("sun_planned") eq "nein" && !@CMDS, "-2 C mittags: kein Plan");

print "\n=== Untergrenze hmFineMin ===\n";
$h = setup(hmRules => "sonne", hmSimulate => 0, hmSunTempReading => "dwd:fc0_12_TTT");
pv(2000); set_rd("dwd", "fc0_12_TTT", 8); set_rd("mySolvis", "C15.TemperaturFeineinstellung_HK2", -3);
$NOW = at_time("06:05"); HeatManager_Sample($h); $NOW = at_time("10:00"); HeatManager_Sample($h);
ok(!@CMDS, "steht schon auf -3 -> nichts");

print "\n=== Saison: 3 kühle Tage -> Thermostate auf auto ===\n";
$h = setup(hmRules => "saison", hmSimulate => 0, hmSeasonForecast => "dwd");
set_rd($_, "mode", "manual") for qw(MAX_A MAX_B MAX_K);
set_rd("dwd", "fc0_Tx", 12); set_rd("dwd", "fc0_Tn", 4); set_rd("dwd", "fc1_Tx", 12); set_rd("dwd", "fc1_Tn", 4);
HeatManager_Season($h);
ok(rd("season") eq "sommer" && rd("season_count") == 1, "Tag 1: " . rd("season_info"));
HeatManager_Season($h); HeatManager_Season($h);
ok(rd("season") eq "heizen", "Tag 3: Heizsaison");
ok((grep { $_ eq "set MAX_A desiredTemperature auto" } @CMDS) ? 1 : 0, "erstes Thermostat auf auto");

print "\n=== Warmer Tag dazwischen setzt den Zähler zurück ===\n";
$h = setup(hmRules => "saison", hmSimulate => 1, hmSeasonForecast => "dwd");
set_rd($_, "mode", "auto") for qw(MAX_A MAX_B MAX_K);       # Ausgangslage: Heizsaison
set_rd("dwd", "fc0_Tx", 22); set_rd("dwd", "fc0_Tn", 14);
HeatManager_Season($h); HeatManager_Season($h);
ok(rd("season_count") == 2 && rd("season") eq "heizen", "warm 2 Tage: " . rd("season_info"));
set_rd("dwd", "fc0_Tx", 15); set_rd("dwd", "fc0_Tn", 8);
HeatManager_Season($h);
ok(rd("season_count") == 0, "kühler Tag -> Zähler 0");
set_rd("dwd", "fc0_Tx", 22); set_rd("dwd", "fc0_Tn", 14);
HeatManager_Season($h) for 1 .. 3;
ok(rd("season") eq "sommer" && rd("sim_saison") =~ /desiredTemperature off/, "3 warme Tage -> Sommer (Simulation)");
done();
