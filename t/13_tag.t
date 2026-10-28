#!/usr/bin/perl
#
# Regel tag: Nachregelung der Heizkurve tagsüber (v0.9.0).

use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd qw(abs_path);
my $stub = dirname(abs_path(__FILE__)) . "/fhem_stub.pl";
require $stub;
our (%defs, %attr, $NOW, @CMDS);

my $FINE = "C15.TemperaturFeineinstellung_HK2";

# Zwei Räume, Ventile weit offen; A mit Raumsensor, B mit Thermostatfühler
sub kalt {
    my (%o) = @_;
    my $h = setup(hmRules => "tag", hmDayTimes => "00:00-23:59", %o);
    for my $t (qw(MAX_A MAX_B)) {
        set_rd($t, "desiredTemperature", 21);
        set_rd($t, "valveposition", $o{_valve} // 70);
    }
    set_rd("SensA", "temperature", $o{_ta} // 19.9);
    set_rd("MAX_B", "temperature", $o{_tb} // 20.0);
    delete $attr{$main::DEVICE}{$_} for grep { /^_/ } keys %{$attr{$main::DEVICE}};
    return $h;
}
sub fine_cmds { return grep { /^set mySolvis $FINE / } @CMDS; }

print "=== Standard: neue Regel simuliert (hmSimOnly tag), auch bei hmSimulate 0 ===\n";
my $h = kalt(hmSimulate => 0);
run_samples($h, 25);
ok(rd("sim_tag") eq "set mySolvis $FINE 1", "sim_tag: " . rd("sim_tag"));
ok(!fine_cmds(), "nichts gesendet");
ok(rd("day_info") =~ /0 -> 1 \(Ventile 70 % seit 120 min, zu kalt: MAX_A 19\.9\/21\.0, MAX_B 20\.0\/21\.0\)/, "day_info: " . rd("day_info"));
ok(rd("day_steps_today") == 1, "Stufe gezählt (auch in der Simulation)");

print "\n=== scharf über hmLive: +1, nach 2 h +2, dann Tageslimit ===\n";
$h = kalt(hmSimulate => 0, hmLive => "tag");
run_samples($h, 25);
ok((fine_cmds())[0] eq "set mySolvis $FINE 1", "erste Stufe gesendet");
run_samples($h, 12);
ok(scalar(fine_cmds()) == 1, "nach 1 h noch keine zweite Stufe (Abstand)");
ok(rd("day_info") =~ /wartet/, "day_info: " . rd("day_info"));
run_samples($h, 12);
ok(scalar(fine_cmds()) == 2 && (fine_cmds())[1] eq "set mySolvis $FINE 2", "nach 2 h zweite Stufe");
run_samples($h, 30);
ok(scalar(fine_cmds()) == 2, "keine dritte Stufe");
ok(rd("day_info") =~ /Tageslimit|Grenze/, "day_info: " . rd("day_info"));

print "\n=== hmFineMax begrenzt ===\n";
$h = kalt(hmLive => "tag", hmFineMax => 0);
run_samples($h, 25);
ok(!fine_cmds() && rd("day_info") =~ /Grenze/, "bei 0 = hmFineMax keine Stufe: " . rd("day_info"));

print "\n=== keine Stufe ===\n";
$h = kalt(hmLive => "tag", _valve => 40);
run_samples($h, 25);
ok(!fine_cmds() && rd("day_info") =~ /ok, Ventile 40 %/, "Ventile 40 %: " . rd("day_info"));

$h = kalt(hmLive => "tag", _tb => 20.6);
run_samples($h, 25);
ok(!fine_cmds() && rd("day_info") =~ /nur 1 Raum/, "nur ein Raum zu kalt: " . rd("day_info"));

$h = kalt(hmLive => "tag");
set_rd("mySolvis", "HumanAccess", "user");
run_samples($h, 25);
ok(!fine_cmds() && rd("day_info") =~ /bedient/, "Regler wird bedient: " . rd("day_info"));

$h = kalt(hmLive => "tag");
set_rd($main::DEVICE, "sun_active", "on");
run_samples($h, 25);
ok(!fine_cmds() && rd("day_info") =~ /Sonne/, "Sonnenabsenkung aktiv: " . rd("day_info"));

$h = kalt(hmLive => "tag", hmDayTimes => "01:00-02:00");
run_samples($h, 25);
ok(!fine_cmds() && rd("day_info") =~ /außerhalb/, "außerhalb des Fensters: " . rd("day_info"));

$h = kalt(hmLive => "tag", hmClimaPresence => "anw:state:on");
set_rd("anw", "state", "off");
run_samples($h, 25);
ok(!fine_cmds() && rd("day_info") =~ /niemand/, "niemand zu Hause: " . rd("day_info"));

$h = kalt(hmLive => "tag");
set_rd("mySolvis", "C12.Anlagenmodus_HK2", "Standby");
run_samples($h, 25);
ok(!fine_cmds() && rd("day_info") =~ /Standby/, "Standby: " . rd("day_info"));

$h = kalt(hmLive => "tag");
run_samples($h, 6);
ok(!fine_cmds() && rd("day_info") =~ /zu wenig Messwerte/, "zu kurz gemessen: " . rd("day_info"));

print "\n=== Status ===\n";
$h = kalt();
run_samples($h, 25);
ok(HeatManager_Get($h, "hm", "status") =~ /Tagsueber: .*\(Simulation\)/, "get status zeigt die Regel");

print "\n=== alte Regeln: hmSimulate 0 bleibt für sie scharf ===\n";
$h = setup(hmSimulate => 0);
ok(HeatManager_Sim("hm", "curve") == 0, "curve scharf bei hmSimulate 0");
ok(HeatManager_Sim("hm", "tag") == 1, "tag simuliert (hmSimOnly)");
$attr{hm}{hmSimOnly} = "none";
ok(HeatManager_Sim("hm", "tag") == 0, "hmSimOnly none -> tag scharf");

done();
