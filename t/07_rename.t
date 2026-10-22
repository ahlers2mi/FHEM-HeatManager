#!/usr/bin/perl
#
# rename: Tagestimer muss unter dem neuen Namen neu eingeplant werden.

use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd qw(abs_path);
my $stub = dirname(abs_path(__FILE__)) . "/fhem_stub.pl";
require $stub;
our (%defs, %attr, $NOW, @CMDS);

my (%timers, @removed);
{
    no warnings qw(redefine once);
    *main::InternalTimer       = sub { my ($t, $fn, $arg) = @_; $timers{$arg} = $fn; };
    *main::RemoveInternalTimer = sub { my ($arg) = @_; push @removed, $arg; delete $timers{$arg}; };
}

print "=== RenameFn registriert ===\n";
my %mh;
HeatManager_Initialize(\%mh);
ok(ref($mh{RenameFn}) eq "CODE", "RenameFn gesetzt");

print "\n=== Umbenennen ===\n";
my $h   = setup(hmRules => "curve");
my $old = $h->{NAME};
HeatManager_ScheduleCheck($h);
ok(exists $timers{"check:$old"}, "Timer check:$old geplant");
$defs{neu} = delete $defs{$old};
$defs{neu}{NAME} = "neu";
$attr{neu} = delete $attr{$old};
HeatManager_Rename("neu", $old);
ok(!exists $timers{"check:$old"}, "alter Timer entfernt");
ok(exists $timers{"check:neu"} && $timers{"check:neu"} eq "HeatManager_CheckTimer", "Timer check:neu geplant");

done();
