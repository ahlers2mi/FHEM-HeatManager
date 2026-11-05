#!/usr/bin/perl
#
# Regel frost (v0.10.0): Grundtemperatur für einen Heizkreis in Standby.

use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd qw(abs_path);
my $stub = dirname(abs_path(__FILE__)) . "/fhem_stub.pl";
require $stub;
our (%defs, %attr, $NOW, @CMDS);

my $RD = "C06.Anlagenmodus_HK1";
sub cmds { return scalar grep { /\Q$_[0]\E/ } @CMDS; }

sub frost_setup {
    my (%o) = @_;
    my $h = setup(hmRules => "frost", hmSimulate => 0, hmSimOnly => "none",
                  hmFrostSensor => "og:temperature", hmLive => "frost",
                  hmNotifyCmd => "msg \$MSG", %o);
    set_rd("mySolvis", $RD, "Standby");
    set_rd("og", "temperature", 15);
    return $h;
}

print "=== ohne Sensor-Attribut: Regel aus ===\n";
my $h = setup(hmRules => "frost", hmSimulate => 0, hmLive => "frost");
set_rd("mySolvis", $RD, "Standby");
HeatManager_Frost($h);
ok(!@CMDS && rd("frost_info") eq "", "kein hmFrostSensor -> nichts");

print "\n=== Hysterese 12/14 ===\n";
$h = frost_setup();
HeatManager_Frost($h);
ok(!@CMDS && rd("frost_temp") eq "15.0", "15 C -> nichts, frost_temp 15.0");
set_rd("og", "temperature", 11.8); HeatManager_Frost($h);
ok(cmds("set mySolvis $RD Tag") && rd("frost_state") eq "heizt", "11.8 C -> Tag, frost_state heizt");
ok(cmds("msg Frostschutz"), "Meldung beim Einschalten");
@CMDS = (); set_rd("og", "temperature", 13.5); HeatManager_Frost($h);
ok(!@CMDS && rd("frost_state") eq "heizt", "13.5 C (zwischen den Schwellen) -> bleibt Tag");
set_rd("og", "temperature", 14.0); HeatManager_Frost($h);
ok(cmds("set mySolvis $RD Standby") && rd("frost_state") eq "aus", "14.0 C -> zurück auf Standby");

print "\n=== Betriebsart von Hand wird respektiert ===\n";
$h = frost_setup();
set_rd("mySolvis", $RD, "Timer");
set_rd("og", "temperature", 10); HeatManager_Frost($h);
ok(!@CMDS && rd("frost_info") =~ /Timer - nichts geschaltet/, "steht auf Timer -> nicht einschalten");
$h = frost_setup();
set_rd("og", "temperature", 10); HeatManager_Frost($h);
set_rd("mySolvis", $RD, "Timer");          # jemand stellt von Hand um
@CMDS = (); set_rd("og", "temperature", 15); HeatManager_Frost($h);
ok(!@CMDS && rd("frost_state") eq "aus" && rd("frost_info") =~ /von Hand/, "von Hand umgestellt -> nicht zurückschalten, Regel gibt frei");

print "\n=== Sensor veraltet ===\n";
$h = frost_setup();
set_rd("og", "temperature", 8);
$NOW += 3 * 3600;                           # Wert ist jetzt 3 h alt
HeatManager_Frost($h);
ok(!cmds("set mySolvis") && rd("frost_info") =~ /ohne Wert/, "3 h alter Wert -> nichts schalten");
ok(cmds("msg HeatManager frost"), "Meldung");
@CMDS = (); $NOW += 3600; HeatManager_Frost($h);
ok(!@CMDS, "1 h später keine zweite Meldung");
$NOW += 6 * 3600; HeatManager_Frost($h);
ok(cmds("msg HeatManager frost"), "nach 6 h erneut gemeldet");

print "\n=== Notbetrieb nach 24 h ohne Sensorwert ===\n";
$h = frost_setup();
set_rd("og", "temperature", 15);
$NOW += 23 * 3600; @CMDS = (); HeatManager_Frost($h);
ok(!cmds("set mySolvis"), "23 h alt -> noch kein Notbetrieb");
$NOW += 2 * 3600; HeatManager_Frost($h);
ok(cmds("set mySolvis $RD Nacht") && rd("frost_state") eq "notbetrieb", "25 h alt -> Nacht, frost_state notbetrieb");
@CMDS = (); $NOW += 300; HeatManager_Frost($h);
ok(!cmds("set mySolvis") && rd("frost_info") =~ /Notbetrieb Nacht/, "bleibt im Notbetrieb, kein neuer Befehl");
@CMDS = (); set_rd("og", "temperature", 11); HeatManager_Frost($h);
ok(cmds("set mySolvis $RD Tag") && rd("frost_state") eq "heizt", "Sensor wieder da, 11 C -> Tag");
ok(rd("frost_stale_since") eq "0", "frost_stale_since zurückgesetzt");

$h = frost_setup();
HeatManager_Frost($h);                                   # 15 C
$NOW += 25 * 3600; HeatManager_Frost($h);
@CMDS = (); set_rd("og", "temperature", 16); HeatManager_Frost($h);
ok(cmds("set mySolvis $RD Standby") && rd("frost_state") eq "aus", "Sensor wieder da, 16 C -> Standby");

$h = frost_setup();
set_rd("mySolvis", $RD, "Timer");                         # Betriebsart von Hand
$NOW += 25 * 3600; HeatManager_Frost($h);
ok(!cmds("set mySolvis") && rd("frost_info") =~ /von Hand auf Timer/, "von Hand Timer -> kein Notbetrieb");

$h = frost_setup();
delete $defs{og}{READINGS}{temperature};                 # Reading fehlt ganz
HeatManager_Frost($h);
ok(!cmds("set mySolvis") && rd("frost_stale_since") == $NOW, "fehlendes Reading: Zeit läuft ab jetzt");
$NOW += 25 * 3600; HeatManager_Frost($h);
ok(cmds("set mySolvis $RD Nacht"), "fehlendes Reading 25 h -> Notbetrieb");

print "\n=== Simulation: frost schaltet nur mit hmLive ===\n";
$h = frost_setup(hmLive => "curve,standby");   # wie beim Nutzer: hmSimulate 0, hmSimOnly none
set_rd("og", "temperature", 10); HeatManager_Frost($h);
ok(!cmds("set mySolvis") && rd("sim_frost") eq "set mySolvis $RD Tag", "nicht in hmLive -> nur sim_frost");
set_rd("og", "temperature", 15); HeatManager_Frost($h);
ok(!cmds("set mySolvis") && rd("sim_frost") eq "set mySolvis $RD Standby", "Simulation läuft durch (zurück auf Standby)");

print "\n=== über die Messung (SampleRun) ===\n";
$h = frost_setup();
set_rd("og", "temperature", 9);
run_samples($h, 1, sub { set_rd("og", "temperature", 9); });
ok(cmds("set mySolvis $RD Tag"), "HeatManager_Sample ruft die Regel auf");
done();
