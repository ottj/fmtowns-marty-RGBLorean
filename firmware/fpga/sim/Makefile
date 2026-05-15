# Run the pcmcia_target testbench with Icarus Verilog.
#
#   brew install icarus-verilog gtkwave        # macOS one-time setup
#
# Targets:
#   make            build and run; prints PASS/FAIL summary
#   make wave       open the resulting VCD in GTKWave
#   make clean      remove build artefacts

RTL_DIR := ../rtl
RTL     := $(RTL_DIR)/pcmcia_target.sv $(RTL_DIR)/sd_reader.sv
# sd_model.sv is sim-only — included where TBs need it.
SD_MODEL := $(RTL_DIR)/sd_model.sv

IVERILOG_FLAGS := -g2012 -Wall -Wno-timescale

# Default: basic PCMCIA-target self-test
all: run

# ---------- TB 1: basic PCMCIA-target ----------
pcmcia_target_tb.vvp: $(RTL) pcmcia_target_tb.sv
	iverilog $(IVERILOG_FLAGS) -o $@ $(RTL) pcmcia_target_tb.sv

run: pcmcia_target_tb.vvp
	vvp pcmcia_target_tb.vvp

wave: pcmcia_target_tb.vcd
	gtkwave pcmcia_target_tb.vcd &

# ---------- TB 2: IPL smoke ----------
# Depends on the x86 IPL artefact existing.
IPL_HEX := ../../x86/ipl/card.hex

$(IPL_HEX):
	@echo "card.hex is missing — building x86 IPL first..."
	$(MAKE) -C ../../x86/ipl

ipl_smoke_tb.vvp: $(RTL) ipl_smoke_tb.sv
	iverilog $(IVERILOG_FLAGS) -o $@ $(RTL) ipl_smoke_tb.sv

ipl: ipl_smoke_tb.vvp $(IPL_HEX)
	vvp ipl_smoke_tb.vvp

ipl-wave: ipl_smoke_tb.vcd
	gtkwave ipl_smoke_tb.vcd &

# ---------- TB 3: mailbox FSM ----------
mailbox_tb.vvp: $(RTL) $(SD_MODEL) mailbox_tb.sv
	iverilog $(IVERILOG_FLAGS) -o $@ $(RTL) $(SD_MODEL) mailbox_tb.sv

mbx: mailbox_tb.vvp
	vvp mailbox_tb.vvp

mbx-wave: mailbox_tb.vcd
	gtkwave mailbox_tb.vcd &

# ---------- TB 4: sd_reader + sd_model end-to-end ----------
sd_reader_tb.vvp: $(RTL_DIR)/sd_reader.sv $(SD_MODEL) sd_reader_tb.sv
	iverilog $(IVERILOG_FLAGS) -o $@ $(RTL_DIR)/sd_reader.sv $(SD_MODEL) sd_reader_tb.sv

sdr: sd_reader_tb.vvp
	vvp sd_reader_tb.vvp

sdr-wave: sd_reader_tb.vcd
	gtkwave sd_reader_tb.vcd &

# ---------- Aggregate ----------
test: run ipl mbx sdr

clean:
	rm -f *.vvp *.vcd

.PHONY: all run wave ipl ipl-wave mbx mbx-wave sdr sdr-wave test clean
