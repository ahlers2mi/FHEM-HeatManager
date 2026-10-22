#!/usr/bin/perl
#
# Status nach define/defmod und nach Neustart: letzte Entscheidung statt "initialized".

use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd qw(abs_path);
my $stub = dirname(abs_path(__FILE__)) . "/fhem_stub.pl";
require $stub;
our (%defs, %attr, $NOW, @CMDS);

print "=== neues Gerät ===\n";
my $h = setup();
my $n = $h->{NAME};
ok(rd("state") eq "initialized", "ohne decision -> initialized");

print "\n=== defmod mit vorhandener Entscheidung ===\n";
set_rd($n, "decision", "Ventile im Mittel 4.6 %, kein Raum zu kalt");
HeatManager_Define($h, "$n HeatManager");
ok(rd("state") eq "Ventile im Mittel 4.6 %, kein Raum zu kalt", "Status = letzte Entscheidung");

print "\n=== Neustart: Statefile nach define ===\n";
set_rd($n, "state", "initialized");
delete $h->{helper}{restoreDone};
HeatManager_restoreState($h);
ok(rd("state") eq "Ventile im Mittel 4.6 %, kein Raum zu kalt", "restoreState setzt Status aus decision");

done();
