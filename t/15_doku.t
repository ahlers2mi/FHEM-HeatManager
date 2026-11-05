#!/usr/bin/perl
#
# Commandref (v0.9.1): jedes Attribut der AttrList hat einen Eintrag mit Anker.
# v0.10.1: Anker im <li>, sonst zeigt FHEMWEB beim attr-Dropdown keine Hilfe.

use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd qw(abs_path);
my $stub = dirname(abs_path(__FILE__)) . "/fhem_stub.pl";
require $stub;

my $file = dirname(abs_path(__FILE__)) . "/../FHEM/98_HeatManager.pm";
open(my $fh, "<", $file) or die $!;
my $src = do { local $/; <$fh> };
close($fh);
my ($doc) = $src =~ /=begin html(.*)=end html/s;

my $h = { NAME => "x" };
HeatManager_Initialize($h);
foreach my $a (map { (split(/:/, $_))[0] } split(/\s+/, $h->{AttrList})) {
    next if ($a eq "");
    ok($doc =~ /id="HeatManager-attr-\Q$a\E"/, "Attribut $a dokumentiert");
    # FHEMWEB zeigt die Hilfe unter dem attr-Dropdown nur, wenn der Anker in
    # einem <li> steht (fhemweb.js FW_displayHelp) - nicht in einer Tabellenzelle
    ok($doc =~ /<li><a id="HeatManager-attr-\Q$a\E"/, "Attribut $a: Anker im <li> (Hilfe im Dropdown)");
}
ok($doc =~ /Die Regeln auf einen Blick/, "Regelübersicht vorhanden");
done();
