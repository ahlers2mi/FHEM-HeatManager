#!/usr/bin/perl
#
# hmLive: einzelne Regeln trotz hmSimulate 1 scharf schalten.

use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd qw(abs_path);
my $stub = dirname(abs_path(__FILE__)) . "/fhem_stub.pl";
require $stub;
our (%defs, %attr, $NOW, @CMDS);

print "=== HeatManager_Sim ===\n";
my $h = setup(hmRules => "curve,ofen", hmSimulate => 1, hmOvenRooms => "MAX_A");
my $n = $h->{NAME};
ok(HeatManager_Sim($n, "ofen") == 1,  "hmSimulate 1, hmLive leer -> ofen simuliert");
$attr{$n}{hmLive} = "ofen,saison";
ok(HeatManager_Sim($n, "ofen") == 0,  "ofen in hmLive -> scharf");
ok(HeatManager_Sim($n, "saison") == 0, "saison in hmLive -> scharf");
ok(HeatManager_Sim($n, "klima") == 1, "klima nicht in hmLive -> simuliert");
$attr{$n}{hmSimulate} = 0;
ok(HeatManager_Sim($n, "klima") == 0, "hmSimulate 0 -> alles scharf");

print "\n=== Ofen simuliert (hmLive leer) ===\n";
$h = setup(hmRules => "curve,ofen", hmSimulate => 1, hmOvenRooms => "MAX_A");
set_rd("MAX_A", "mode", "auto");
set_rd("ofen", "Temperatur", "80");
run_samples($h, 1);
ok(!(grep { /MAX_A desiredTemperature/ } @CMDS), "kein echter Befehl");
ok(rd("sim_ofen") eq "set MAX_A desiredTemperature 17", "sim_ofen " . rd("sim_ofen"));

print "\n=== Ofen scharf (hmLive ofen), Rest simuliert ===\n";
$h = setup(hmRules => "curve,ofen", hmSimulate => 1, hmLive => "ofen", hmOvenRooms => "MAX_A");
set_rd("MAX_A", "mode", "auto");
set_rd("ofen", "Temperatur", "80");
run_samples($h, 1);
ok((grep { $_ eq "set MAX_A desiredTemperature 17" } @CMDS) ? 1 : 0, "MAX_A wirklich auf 17");
ok(rd("sim_ofen") eq "", "kein sim_ofen");
@CMDS = (); set_rd("ofen", "Temperatur", 20); set_rd("kachel", "temperature", 20);
set_rd("MAX_A", "desiredTemperature", 17);
run_samples($h, 1);
ok((grep { $_ eq "set MAX_A desiredTemperature auto" } @CMDS) ? 1 : 0, "Ofen aus -> MAX_A wirklich zurück auf auto");

done();
