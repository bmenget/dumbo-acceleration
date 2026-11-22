# Out-of-context synthesis + implementation of the LWC top for one design point and one clock target.
# Called by scripts/synth.py; can also be run by hand:
#   vivado -mode batch -nojournal -nolog -source scripts/vivado_build.tcl \
#          -tclargs <filelist.txt> <period_ns> <outdir> <part> <top> [flow]
#
# flow (optional, default "base"):
#   base   the project's standard flow: synthesis without a clock (not timing-driven), the clock is created
#          after synthesis, default directives everywhere. All results in reports/synth_*.csv use it.
#   tsyn   the clock is read before synthesis (timing-driven synthesis), default directives
#   perf   tsyn + timing directives: synth PerformanceOptimized, opt Explore, place ExtraTimingOpt,
#          phys_opt / route AggressiveExplore, and a post-route phys_opt
#   area   tsyn + area directives: synth AreaOptimized_high (no BRAM), opt ExploreArea
#
# Out-of-context: no I/O constraints, so only register-to-register paths inside the design are timed.
# That is what we want for Fmax of the core + wrapper (pad delays would dominate otherwise).

set filelist [lindex $argv 0]
set period   [lindex $argv 1]
set outdir   [lindex $argv 2]
set part     [lindex $argv 3]
set top      [lindex $argv 4]
set flow     [expr {[llength $argv] > 5 ? [lindex $argv 5] : "base"}]
if {[lsearch -exact {base tsyn perf area} $flow] < 0} { error "unknown flow $flow" }

file mkdir $outdir
set_param general.maxThreads 8

# Compile-ordered VHDL files, absolute paths. VHDL-2008 is required (process(all) in CryptoCore).
set fh [open $filelist r]
set files [split [string trim [read $fh]] "\n"]
close $fh
foreach f $files { read_vhdl -vhdl2008 $f }

set sdir {}
set odir {}
set pdir {}
set xdir {}
set rdir {}
if {$flow eq "perf"} {
    set sdir {-directive PerformanceOptimized}
    set odir {-directive Explore}
    set pdir {-directive ExtraTimingOpt}
    set xdir {-directive AggressiveExplore}
    set rdir {-directive AggressiveExplore}
} elseif {$flow eq "area"} {
    # no Block RAM: the comparison with GMU's designs is in LUTs, so moving logic into BRAM would not count
    set sdir {-directive AreaOptimized_high -max_bram 0}
    set odir {-directive ExploreArea}
}
if {$flow eq "base"} {
    synth_design -top $top -part $part -mode out_of_context
    create_clock -period $period -name clk [get_ports clk]
} else {
    # clock known to synthesis: timing-driven synthesis
    set xdc $outdir/clock.xdc
    set fh [open $xdc w]
    puts $fh "create_clock -period $period -name clk \[get_ports clk\]"
    close $fh
    read_xdc -mode out_of_context $xdc
    synth_design -top $top -part $part -mode out_of_context {*}$sdir
}

opt_design {*}$odir
place_design {*}$pdir
phys_opt_design {*}$xdir
route_design {*}$rdir
if {$flow eq "perf"} {
    phys_opt_design -directive AggressiveExplore
}

report_timing_summary -delay_type max -max_paths 5 -file $outdir/timing.rpt
report_utilization -file $outdir/util.rpt
report_utilization -hierarchical -hierarchical_depth 4 -file $outdir/util_hier.rpt

# Every LUT / FF / mux / distributed-RAM cell with its type, for grouping area by register or function
# (cell names follow the register or net they drive).
set fh [open $outdir/cells.tsv w]
puts $fh "cell\tref"
set prims [get_cells -hierarchical -filter {IS_PRIMITIVE && REF_NAME =~ "LUT*" || REF_NAME =~ "FD*" || REF_NAME =~ "MUXF*" || REF_NAME =~ "RAM*" || REF_NAME =~ "SRL*"}]
foreach c $prims ref [get_property REF_NAME $prims] { puts $fh "$c\t$ref" }
close $fh

# One line per path (the worst path to each endpoint, up to 1000) for scripts/critpath.py's summary of
# distinct critical-path categories. perm_cells counts logic cells inside a permutation unit; keep the
# pattern in step with PERM_MARK in critpath.py.
set fh [open $outdir/paths.tsv w]
puts $fh "slack\tlevels\tdelay\tlogic\tsource\tdest\tcells\tperm_cells"
foreach p [get_timing_paths -setup -max_paths 1000 -nworst 1] {
    set n 0
    set np 0
    set cells [get_cells -quiet -of_objects $p]
    if {[llength $cells] > 0} {
        foreach c $cells ref [get_property REF_NAME $cells] {
            if {[regexp {^(LUT|CARRY|MUXF)} $ref]} {
                incr n
                if {[regexp {/(PERM|PERM_B)/|gen_stage\[[0-9]+\]\.ST/|gen_perm\[[0-9]+\]\.P/} $c]} { incr np }
            }
        }
    }
    puts $fh [join [list [get_property SLACK $p] [get_property LOGIC_LEVELS $p] \
        [get_property DATAPATH_DELAY $p] [get_property DATAPATH_LOGIC_DELAY $p] \
        [get_property STARTPOINT_PIN $p] [get_property ENDPOINT_PIN $p] $n $np] "\t"]
}
close $fh

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
puts $fh "flow=$flow"
close $fh
exit
