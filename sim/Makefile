# retro68k simulation (Icarus Verilog)
#
#   make            build and run the system test
#   make run ARGS=+dma      with the DMA port kept busy
#   make run ARGS=+trace    print the first bus cycles
#
# Needs: iverilog, sv2v (to convert fx68k), vasmm68k_mot, python3.
# Tools can be given explicitly: make SV2V=/path/sv2v VASM=/path/vasmm68k_mot

SV2V  ?= sv2v
VASM  ?= vasmm68k_mot
IVERILOG ?= iverilog
VVP   ?= vvp

ROOT  := ..
RTL   := $(ROOT)/fpga/rtl
FX68K := $(ROOT)/fpga/third_party/fx68k
BUILD := build

RTL_SRC := $(RTL)/timebase.v $(RTL)/cpu_fx68k.v $(RTL)/sram_ctl.v $(RTL)/dmac.v $(RTL)/bus_if.v \
           $(RTL)/bootrom.v $(RTL)/fifo8.v $(RTL)/sysregs.v $(RTL)/serial.v $(RTL)/intc.v $(RTL)/timers.v $(RTL)/layer_pix.v $(RTL)/bpldma.v $(RTL)/sprite_pix.v $(RTL)/sprites.v $(RTL)/video.v $(RTL)/copper.v $(RTL)/audio.v $(RTL)/dmx.v $(RTL)/sdspi.v $(RTL)/ps2kb.v $(RTL)/retro68k.v
SIM_SRC := $(RTL)/platform/sim/oddr.v sram_model.v ft232h_model.v sd_model.v ps2_model.v tb.v

.PHONY: vtest ctest atest dtest iotest rtest serial all run frame clean
all: run

$(BUILD):
	mkdir -p $(BUILD)

# fx68k is SystemVerilog; Icarus needs it as Verilog
$(BUILD)/fx68k.v: $(FX68K)/fx68k.sv $(FX68K)/fx68kAlu.sv $(FX68K)/uaddrPla.sv | $(BUILD)
	$(SV2V) $^ > $@

$(BUILD)/microrom.mem $(BUILD)/nanorom.mem: | $(BUILD)
	cp $(FX68K)/microrom.mem $(FX68K)/nanorom.mem $(BUILD)/

$(BUILD)/boot.bin: $(ROOT)/firmware/boot/boot.s $(ROOT)/firmware/boot/font8x16.bin $(ROOT)/firmware/include/hw.inc | $(BUILD)
	$(VASM) -quiet -Fbin -DSIM -I $(ROOT)/firmware/include -I $(ROOT)/firmware/boot -o $@ $<

$(BUILD)/boot.hex: $(BUILD)/boot.bin
	python3 $(ROOT)/tools/bin2hex.py $< $@

$(BUILD)/tb.vvp: $(BUILD)/fx68k.v $(RTL_SRC) $(SIM_SRC) $(RTL)/regmap.vh
	$(IVERILOG) -g2005 -Wall -Wno-timescale -Wno-implicit-dimensions -I $(RTL) -s tb -o $@ \
	    $(BUILD)/fx68k.v $(RTL_SRC) $(SIM_SRC)

run: $(BUILD)/tb.vvp $(BUILD)/boot.hex $(BUILD)/microrom.mem
	cd $(BUILD) && $(VVP) -n tb.vvp $(ARGS) | tee sim.log
	@grep -q "^TEST PASSED" $(BUILD)/sim.log

# The screen as a PNG (needs Pillow): runs the test with +frame
frame: $(BUILD)/tb.vvp $(BUILD)/boot.hex $(BUILD)/microrom.mem
	cd $(BUILD) && $(VVP) -n tb.vvp +frame $(ARGS) | tee sim.log
	python3 -c "from PIL import Image; Image.open('$(BUILD)/frame.ppm').save('$(BUILD)/frame.png')"
	@echo "wrote $(BUILD)/frame.png"

# Video test (spec 4): random pictures in every layer format, checked pixel by
# pixel against a Python model (vtest/vmodel.py); a palette screen and a
# direct-colour screen and a sprite screen, and the sprite screen again
# with every layer and sprite on PALETTE0 (VIDCON.SHAREPAL)
VTESTS = pal direct spr share
vtest: $(BUILD)/tb.vvp $(BUILD)/microrom.mem
	@set -e; for t in $(VTESTS); do \
	    d=$(BUILD)/vtest_$$t; mkdir -p $$d; \
	    flag=; gen=; [ $$t = direct ] && flag=-DDIRECT && gen=--direct; \
	    [ $$t = spr ] && flag=-DSPRITES && gen=--sprites; 	    [ $$t = share ] && flag="-DSPRITES -DSHARE" && gen=--sprites; \
	    $(VASM) -quiet -Fbin $$flag -I $(ROOT)/firmware/include -o $$d/vtest.bin vtest/vtest.s; \
	    python3 $(ROOT)/tools/bin2hex.py $$d/vtest.bin $$d/vtest.hex; \
	    python3 vtest/vgen.py $$d/ram.hex $$gen; \
	    cp $(BUILD)/microrom.mem $(BUILD)/nanorom.mem $$d/; \
	    (cd $$d && $(VVP) -n ../tb.vvp +frame +rom=vtest.hex +ram=ram.hex > sim.log); \
	    grep -q "^TEST PASSED" $$d/sim.log || { tail -n 20 $$d/sim.log; exit 1; }; \
	    python3 vtest/vmodel.py $$d $$d/ram.hex $$d/model.png; \
	done

# Copper test (spec 10): a self-checking ROM (registers, ALU, conditions,
# CALL/RET, MOVR, COPINT, RESUME), then the frame checked for colour
# changes at beam positions (ctest/ccheck.py)
ctest: $(BUILD)/tb.vvp $(BUILD)/microrom.mem
	@set -e; d=$(BUILD)/ctest; mkdir -p $$d; \
	$(VASM) -quiet -Fbin -I $(ROOT)/firmware/include -o $$d/ctest.bin ctest/ctest.s; \
	python3 $(ROOT)/tools/bin2hex.py $$d/ctest.bin $$d/ctest.hex; \
	cp $(BUILD)/microrom.mem $(BUILD)/nanorom.mem $$d/; \
	(cd $$d && $(VVP) -n ../tb.vvp +frame +rom=ctest.hex +timeout=200000000 > sim.log); \
	grep -a "^FAIL\|^PASS" $$d/sim.log || true; \
	grep -q "^TEST PASSED" $$d/sim.log || { tail -n 20 $$d/sim.log; exit 1; }; \
	python3 ctest/ccheck.py $$d

# DMA engine test (spec 11): random jobs on the 4 channels (dtest/dgen.py;
# SEED picks them), then every byte of the test area checked against a
# Python model (dtest/dmodel.py)
SEED = 11
dtest: $(BUILD)/tb.vvp $(BUILD)/microrom.mem
	@set -e; d=$(BUILD)/dtest; mkdir -p $$d; \
	$(VASM) -quiet -Fbin -I $(ROOT)/firmware/include -o $$d/dtest.bin dtest/dtest.s; \
	python3 $(ROOT)/tools/bin2hex.py $$d/dtest.bin $$d/dtest.hex; \
	python3 dtest/dgen.py $$d $(SEED); \
	cp $(BUILD)/microrom.mem $(BUILD)/nanorom.mem $$d/; \
	(cd $$d && $(VVP) -n ../tb.vvp +rom=dtest.hex +ram=ram.hex +dumpram=after.hex +dmxsend > sim.log); \
	grep -a "^FAIL\|^PASS" $$d/sim.log || true; \
	grep -q "^TEST PASSED" $$d/sim.log || { tail -n 20 $$d/sim.log; exit 1; }; \
	python3 dtest/dmodel.py $$d/jobs.json $$d/ram.hex $$d/after.hex

# I/O test (specs 15, 16): the SD card (start-up, blocks by DMA and by the CPU)
# and the PS/2 keyboard (receiving, a bad frame, sending), against the
# testbench's models
iotest: $(BUILD)/tb.vvp $(BUILD)/microrom.mem
	@set -e; d=$(BUILD)/iotest; mkdir -p $$d; \
	$(VASM) -quiet -Fbin -I $(ROOT)/firmware/include -o $$d/iotest.bin iotest/iotest.s; \
	python3 $(ROOT)/tools/bin2hex.py $$d/iotest.bin $$d/iotest.hex; \
	cp $(BUILD)/microrom.mem $(BUILD)/nanorom.mem $$d/; \
	(cd $$d && $(VVP) -n ../tb.vvp +rom=iotest.hex +iotest > sim.log); \
	grep -a "^FAIL\|^PASS\|^---- io" $$d/sim.log || true; \
	grep -q "^TEST PASSED" $$d/sim.log || { tail -n 20 $$d/sim.log; exit 1; }

# RESET instruction test (spec 7, section 2.4): the devices are reset, the
# CPU, overlay, memory, watchdog, RESETWHY and time counter are not
rtest: $(BUILD)/tb.vvp $(BUILD)/microrom.mem
	@set -e; d=$(BUILD)/rtest; mkdir -p $$d; \
	$(VASM) -quiet -Fbin -I $(ROOT)/firmware/include -o $$d/rtest.bin rtest/rtest.s; \
	python3 $(ROOT)/tools/bin2hex.py $$d/rtest.bin $$d/rtest.hex; \
	cp $(BUILD)/microrom.mem $(BUILD)/nanorom.mem $$d/; \
	(cd $$d && $(VVP) -n ../tb.vvp +rom=rtest.hex > sim.log); \
	grep -a "^FAIL\|^PASS" $$d/sim.log || true; \
	grep -q "^TEST PASSED" $$d/sim.log || { tail -n 20 $$d/sim.log; exit 1; }

# USB link test (spec 14, section 3): serial.v on its own with the FT232H
# model: escapes, control commands, a frame ending in 0x00, CTLLOCK, raw mode
serial:
	@set -e; mkdir -p $(BUILD)/serial; \
	$(IVERILOG) -g2005 -Wall -Wno-timescale -I $(RTL) -s tb_serial -o $(BUILD)/serial/tb_serial.vvp \
	    serial/tb_serial.v $(RTL)/serial.v $(RTL)/fifo8.v ft232h_model.v; \
	$(VVP) -n $(BUILD)/serial/tb_serial.vvp > $(BUILD)/serial/sim.log; \
	grep -a "^FAIL" $(BUILD)/serial/sim.log || true; \
	grep -q "^TEST PASSED" $(BUILD)/serial/sim.log || { tail -n 20 $(BUILD)/serial/sim.log; exit 1; }; \
	echo "serial: PASS"

# Audio test (spec 6): four channels, every output sample checked against
# a Python model (atest/amodel.py), and the DAC streams against the output
atest: $(BUILD)/tb.vvp $(BUILD)/microrom.mem
	@set -e; d=$(BUILD)/atest; mkdir -p $$d; \
	$(VASM) -quiet -Fbin -I $(ROOT)/firmware/include -o $$d/atest.bin atest/atest.s; \
	python3 $(ROOT)/tools/bin2hex.py $$d/atest.bin $$d/atest.hex; \
	python3 atest/agen.py $$d/ram.hex; \
	cp $(BUILD)/microrom.mem $(BUILD)/nanorom.mem $$d/; \
	(cd $$d && $(VVP) -n ../tb.vvp +audio +rom=atest.hex +ram=ram.hex > sim.log); \
	grep -q "^TEST PASSED" $$d/sim.log || { tail -n 20 $$d/sim.log; exit 1; }; \
	python3 atest/amodel.py $$d $$d/ram.hex

clean:
	rm -rf $(BUILD)
