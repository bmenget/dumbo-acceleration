# Out-of-context synthesis + implementation of the LWC top for one design point and one clock target.
# Called by scripts/synth_sweep.py; can also be run by hand:
#   vivado -mode batch -nojournal -nolog -source scripts/vivado_build.tcl \
#          -tclargs <filelist.txt> <period_ns> <outdir> <part> <top>
#
# Out-of-context: no I/O constraints, so only register-to-register paths inside the design are timed.
# That is what we want for Fmax of the core + wrapper (pad delays would dominate otherwise).

set filelist [lindex $argv 0]
set period   [lindex $argv 1]
set outdir   [lindex $argv 2]
set part     [lindex $argv 3]
set top      [lindex $argv 4]

file mkdir $outdir
set_param general.maxThreads 8

# Compile-ordered VHDL files, absolute paths. VHDL-2008 is required (process(all) in CryptoCore).
set fh [open $filelist r]
set files [split [string trim [read $fh]] "\n"]
close $fh
foreach f $files { read_vhdl -vhdl2008 $f }

synth_design -top $top -part $part -mode out_of_context
create_clock -period $period -name clk [get_ports clk]

opt_design
place_design
phys_opt_design
route_design

report_timing_summary -delay_type max -max_paths 5 -file $outdir/timing.rpt
report_utilization -file $outdir/util.rpt

set paths [get_timing_paths -setup -max_paths 1 -nworst 1]
if {[llength $paths] > 0} {
    set wns [get_property SLACK [lindex $paths 0]]
} else {
    set wns "NA"
}

set fh [open $outdir/summary.txt w]
puts $fh "wns=$wns"
puts $fh "period=$period"
puts $fh "part=$part"
puts $fh "vivado=[version -short]"
close $fh
exit
