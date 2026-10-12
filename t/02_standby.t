#!/usr/bin/perl
#
# Regel standby: Hysterese und Mindestverweildauer.

use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd qw(abs_path);
my $stub = dirname(abs_path(__FILE__)) . "/fhem_stub.pl";
require $stub;
our (%defs, %attr, $NOW, @CMDS);

my $h = setup(hmRules => "standby", hmSimulate => 0);
print "=== Standby-Hysterese ===\n";
HeatManager_Standby($h, 1.0);
ok((grep { /C12.Anlagenmodus_HK2 Standby/ } @CMDS) ? 1 : 0, "1.0 % -> Standby");
@CMDS = (); $NOW += 600; HeatManager_Standby($h, 5);
ok(!@CMDS && rd("standby_info") =~ /Mindestzeit/, "nach 10 min kein Wechsel (Mindestzeit)");
@CMDS = (); $NOW += 1800; HeatManager_Standby($h, 2.5);
ok(!@CMDS, "2.5 % (zwischen den Schwellen) -> bleibt Standby");
HeatManager_Standby($h, 3.5);
ok((grep { /C12.Anlagenmodus_HK2 Timer/ } @CMDS) ? 1 : 0, "3.5 % -> Timer");

print "\n=== Ausgangszustand vom Wärmeerzeuger ===\n";
$h = setup(hmRules => "standby", hmSimulate => 0);
set_rd("mySolvis", "C12.Anlagenmodus_HK2", "Standby");
HeatManager_Standby($h, 1.0);
ok(!@CMDS, "steht schon auf Standby -> kein Befehl");
done();
