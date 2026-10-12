#!/usr/bin/perl
#
# Minimaler FHEM-Ersatz, damit 98_HeatManager.pm ohne laufende FHEM-Instanz
# getestet werden kann (Vorbild: FHEM-Pool/t/fhem_stub.pl). Wird von den
# .t-Dateien per require geladen und lädt selbst das Modul.
#
# Warum ein Stub: die Regeln sind reine Entscheidungslogik über Readings,
# Attribute und Uhrzeit. Die lässt sich hier deterministisch durchspielen -
# inklusive 24 Stunden Messwerte in Sekunden.
#
# Die Uhr ist simulierbar: time() und localtime() werden in einem BEGIN-Block
# abgefangen, also bevor das Modul kompiliert wird.

use strict;
use warnings;

BEGIN {
    *CORE::GLOBAL::time      = sub { defined $main::NOW ? $main::NOW : CORE::time() };
    *CORE::GLOBAL::localtime = sub {
        return CORE::localtime(@_ ? $_[0]
                               : (defined $main::NOW ? $main::NOW : CORE::time()));
    };
}

our (%defs, %attr, $init_done, $readingFnAttributes, $NOW);
our @CMDS;                  # Protokoll aller per AnalyzeCommandChain gesendeten Befehle
our $DEVICE = "hm";

$init_done           = 1;
$readingFnAttributes = "";
$NOW                 = 1_800_000_000;     # 2027-01-15 09:00 MEZ

# --- von fhem.pl bereitgestellte Funktionen ---------------------------------
sub Log3 { }
sub AttrVal {
    my ($n, $a, $d) = @_;
    return (exists $attr{$n} && defined $attr{$n}{$a} && $attr{$n}{$a} ne "")
        ? $attr{$n}{$a} : $d;
}
sub ReadingsVal {
    my ($n, $r, $d) = @_;
    return $d if (!exists $defs{$n} || !exists $defs{$n}{READINGS}{$r});
    return $defs{$n}{READINGS}{$r}{VAL};
}
sub gettimeofday         { return $NOW; }
sub InternalTimer        { }
sub RemoveInternalTimer  { }
sub FmtDateTime          { return "ts"; }
sub IsDisabled           { return 0; }
sub readingsBeginUpdate  { }
sub readingsEndUpdate    { }
sub readingsBulkUpdate   { my ($h,$r,$v)=@_; $h->{READINGS}{$r}{VAL}=$v; }
sub readingsSingleUpdate { my ($h,$r,$v)=@_; $h->{READINGS}{$r}{VAL}=$v; }
sub readingsDelete       { my ($h,$r)=@_;    delete $h->{READINGS}{$r}; }
sub devspec2array        { return sort grep { ($defs{$_}{TYPE} // "") eq "HeatingThermostat" } keys %defs; }
sub AnalyzeCommandChain {
    my (undef, $c) = @_;
    push @CMDS, $c;
    # Schaltbefehl auf dem Stub-Gerät nachziehen, damit Folgezyklen ihn sehen
    if ($c =~ /^set (\S+) (\S+) (\S+)$/ && exists $defs{$1}) {
        $defs{$1}{READINGS}{$2}{VAL} = $3;
    }
    return undef;
}

# --- Modul laden ------------------------------------------------------------
my $modul = __FILE__;
$modul =~ s{/[^/]+$}{};
$modul .= "/../FHEM/98_HeatManager.pm";
do $modul or die "Konnte $modul nicht laden: " . ($@ || $!) . "\n";

# ---------------------------------------------------------------------------
# Testhilfen
# ---------------------------------------------------------------------------
our $FAILS = 0;
our $OKS   = 0;

sub ok {
    my ($cond, $text) = @_;
    printf("%-5s %s\n", $cond ? "ok" : "FAIL", $text);
    $cond ? $OKS++ : $FAILS++;
    return $cond ? 1 : 0;
}

sub done {
    printf("\n%d ok, %d FAILED\n", $OKS, $FAILS);
    exit($FAILS ? 1 : 0);
}

# Reading des Testgeräts bzw. eines beliebigen Geräts
sub rd  { my ($r, $d) = @_; return ReadingsVal($d // $DEVICE, $r, ""); }
sub set_rd { my ($d, $r, $v) = @_; $defs{$d}{NAME} //= $d; $defs{$d}{READINGS}{$r}{VAL} = $v; }

# Standard-Anlage: zwei Thermostate (A mit Raumsensor, B), ein Keller K
# (ignoriert), Solvis, Klima-Dummy, Heizgrenze, Akku, Wechselrichter, Ofen.
sub setup {
    my (%o) = @_;
    %defs = (); %attr = (); @CMDS = ();
    for my $t (qw(MAX_A MAX_B MAX_K)) {
        $defs{$t} = { NAME => $t, TYPE => "HeatingThermostat",
                      READINGS => { desiredTemperature => { VAL => 20 }, valveposition => { VAL => 10 } } };
    }
    set_rd("MAX_K", "desiredTemperature", 15);  set_rd("MAX_K", "valveposition", 90);
    set_rd("SensA", "temperature", 21);
    set_rd("mySolvis", "C15.TemperaturFeineinstellung_HK2", 0);
    set_rd("mySolvis", "C12.Anlagenmodus_HK2", "Timer");
    set_rd("mySolvis", "HumanAccess", "none");
    set_rd("d_clima", "mode", "auto");   set_rd("d_clima", "auto_on", "off");
    set_rd("ac", "power", "Off");         set_rd("ac", "mode", "Heat");
    set_rd("d_gate", "freigabe", "on");
    set_rd("bms", "soc", 80);
    set_rd("wr", "netzspannung", "230");
    set_rd("d_solar", "index", 0);
    set_rd("ofen", "Temperatur", 21);     set_rd("kachel", "temperature", 20);
    set_rd("aussen", "temperature", 8);

    my $h = { NAME => $DEVICE, TYPE => "HeatManager", READINGS => {} };
    $defs{$DEVICE} = $h;
    HeatManager_Define($h, "$DEVICE HeatManager");
    %{$attr{$DEVICE}} = (
        hmIgnore => "MAX_K", hmRoomSensors => "MAX_A:SensA",
        hmClimaRoom => "MAX_A", hmClimaDevice => "d_clima", hmClimaAc => "ac",
        hmClimaGate => "d_gate", hmClimaSocReading => "bms:soc", hmClimaAffected => "MAX_B",
        hmClimaTimes => "00:00-23:59", hmGridSensor => "wr:netzspannung",
        hmEmergencyReading => "d_solar:index", hmOvenSensor => "ofen:Temperatur",
        hmOvenTileSensor => "kachel:temperature", hmOvenRooms => "none",
        hmOutdoorSensor => "aussen:temperature",
        %o,
    );
    return $h;
}

# n Messungen im 5-min-Takt
sub run_samples {
    my ($h, $n, $cb) = @_;
    for (1 .. $n) { $NOW += 300; $cb->() if ($cb); HeatManager_Sample($h); }
}

# 24 h Messwerte mit festen Ventilen/Temperatur
sub day {
    my ($h, $va, $vb, $ta, $des) = @_;
    $h->{helper}{samples} = [];
    run_samples($h, 288, sub {
        set_rd("MAX_A", "desiredTemperature", $des); set_rd("MAX_A", "valveposition", $va);
        set_rd("MAX_B", "desiredTemperature", $des); set_rd("MAX_B", "valveposition", $vb);
        set_rd("SensA", "temperature", $ta);
    });
}

1;
