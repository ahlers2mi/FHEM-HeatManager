#!/usr/bin/perl
#
# Vorlauftemperatur (hmFlowSensor): nur Anzeige, ändert keine Entscheidung.

use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd qw(abs_path);
my $stub = dirname(abs_path(__FILE__)) . "/fhem_stub.pl";
require $stub;
our (%defs, %attr, $NOW, @CMDS);

print "=== Vorlauf schwankt 30..50 °C ===\n";
my $h = setup(hmRules => "curve", hmFlowSensor => "mySolvis:S12.Vorlauftemperatur_HK1");
my $i = 0;
$h->{helper}{samples} = [];
run_samples($h, 288, sub {
    set_rd("MAX_A", "desiredTemperature", 20); set_rd("MAX_A", "valveposition", 5);
    set_rd("MAX_B", "desiredTemperature", 20); set_rd("MAX_B", "valveposition", 4);
    set_rd("SensA", "temperature", 21);
    set_rd("mySolvis", "S12.Vorlauftemperatur_HK1", ($i++ % 2) ? 50 : 30);
});
ok(rd("flow_now") =~ /^(30|50)\.0$/, "flow_now " . rd("flow_now"));
HeatManager_Curve($h);
ok(rd("flow_avg_24h") == 40, "flow_avg_24h 40 (" . rd("flow_avg_24h") . ")");
ok(rd("flow_min_24h") == 30 && rd("flow_max_24h") == 50, "min/max 30/50");
ok(rd("decision") =~ /Vorlauf Ø 40 °C \(30-50\)/, "decision: " . rd("decision"));
ok(rd("fine_target") == -1, "Entscheidung unverändert -1");
my $st = HeatManager_Get($h, "hm", "status");
ok($st =~ /Vorlauf:\s+jetzt \d+\.0 °C, 24h Ø 40\.0 °C \(30\.0-50\.0\)/, "get status Vorlauf");

print "\n=== Fühler offen (250 °C) und hmFlowSensor none ===\n";
$h = setup(hmRules => "curve", hmFlowSensor => "mySolvis:S13.Vorlauftemperatur_HK2");
set_rd("mySolvis", "S13.Vorlauftemperatur_HK2", 250);
run_samples($h, 3);
ok(rd("flow_now") eq "?", "250 °C verworfen");
ok(!grep({ defined $_->{flow} } @{$h->{helper}{samples}}), "kein flow im Sample");
$h = setup(hmRules => "curve", hmFlowSensor => "none");
run_samples($h, 3);
ok(rd("flow_now") eq "", "none -> kein Reading");

print "\n=== Restore: flow übersteht .samples ===\n";
$h = setup(hmRules => "curve", hmFlowSensor => "mySolvis:S12.Vorlauftemperatur_HK1");
set_rd("mySolvis", "S12.Vorlauftemperatur_HK1", 35.5);
run_samples($h, 12);
my $saved = rd(".samples");
ok($saved =~ /"flow":35\.5/, ".samples enthält flow");

done();
