# Build the RGBLorean Marty IC-card boot image.
#
# Outputs:
#   bootsec.bin     512 B, IPL4 magic + pointers (sector 0)
#   iosys_stub.bin  512 B, fake IO.SYS loaded to 0x400 (sector 1)
#   card.bin        1 024 B (bootsec + iosys_stub), raw image
#   card_64k.bin    65 536 B (card.bin padded with 0xFF), matches the size of
#                   captainys' working ICMIMAGE.BIN reference — use this with
#                   Tsugaru / MAME, the Marty BIOS appears to bail on a
#                   too-small JEIDA4 image
#   card.hex        $readmemh-compatible 16-bit words for FPGA BRAM init
#                   (built from card.bin — small image keeps the BRAM modest)
#
# One-time setup (macOS):
#   brew install nasm
#
# Run:
#   make            # build everything
#   make clean      # remove artefacts

NASM := nasm
PY   := python3

BIN2HEX := ../tools/bin2hex.py

# 64 KB matches the working reference image ICMIMAGE.BIN
CARD_SIZE := 65536

RESIDENT_DIR := ../resident

OUTS := bootsec.bin iosys_stub.bin mbx_test.bin int93_tsr.bin int93_fwd.bin \
        card.bin card_64k.bin card.hex \
        card_mbx.bin card_mbx_64k.bin \
        card_tsr.bin card_tsr_64k.bin \
        card_fwd.bin card_fwd_64k.bin

all: $(OUTS)
	@echo
	@echo "Built:"
	@ls -l $(OUTS)

bootsec.bin: bootsec.asm
	$(NASM) -f bin -o $@ $<

iosys_stub.bin: iosys_stub.asm
	$(NASM) -f bin -o $@ $<

mbx_test.bin: $(RESIDENT_DIR)/mbx_test.asm
	$(NASM) -f bin -o $@ $<

int93_tsr.bin: $(RESIDENT_DIR)/int93_tsr.asm
	$(NASM) -f bin -o $@ $<

int93_fwd.bin: $(RESIDENT_DIR)/int93_fwd.asm
	$(NASM) -f bin -o $@ $<

card.bin: bootsec.bin iosys_stub.bin
	cat bootsec.bin iosys_stub.bin > $@

# Mailbox-test variant — same boot sector, mbx_test.bin replaces iosys_stub.bin.
# Use this for end-to-end mailbox validation on real hardware.
card_mbx.bin: bootsec.bin mbx_test.bin
	cat bootsec.bin mbx_test.bin > $@

card_mbx_64k.bin: card_mbx.bin
	$(PY) -c "import sys; \
	d=open('card_mbx.bin','rb').read(); \
	pad=$(CARD_SIZE)-len(d); \
	assert pad>=0, 'card_mbx.bin already > $(CARD_SIZE) bytes'; \
	open('card_mbx_64k.bin','wb').write(d + b'\xff'*pad)"

# TSR card image (int 0x93 hook test).
card_tsr.bin: bootsec.bin int93_tsr.bin
	cat bootsec.bin int93_tsr.bin > $@

card_tsr_64k.bin: card_tsr.bin
	$(PY) -c "import sys; \
	d=open('card_tsr.bin','rb').read(); \
	pad=$(CARD_SIZE)-len(d); \
	assert pad>=0, 'card_tsr.bin already > $(CARD_SIZE) bytes'; \
	open('card_tsr_64k.bin','wb').write(d + b'\xff'*pad)"

# Forwarding TSR card image (AL=0xC0 / AH=0x05 decode + log).
card_fwd.bin: bootsec.bin int93_fwd.bin
	cat bootsec.bin int93_fwd.bin > $@

card_fwd_64k.bin: card_fwd.bin
	$(PY) -c "import sys; \
	d=open('card_fwd.bin','rb').read(); \
	pad=$(CARD_SIZE)-len(d); \
	assert pad>=0, 'card_fwd.bin already > $(CARD_SIZE) bytes'; \
	open('card_fwd_64k.bin','wb').write(d + b'\xff'*pad)"

# Pad card.bin with 0xFF up to 64 KB. Use python for portability — `tr` on macOS
# behaves differently than on GNU and `head -c` doesn't accept all suffixes.
card_64k.bin: card.bin
	$(PY) -c "import sys; \
	d=open('card.bin','rb').read(); \
	pad=$(CARD_SIZE)-len(d); \
	assert pad>=0, 'card.bin already > $(CARD_SIZE) bytes'; \
	open('card_64k.bin','wb').write(d + b'\xff'*pad)"

card.hex: card.bin $(BIN2HEX)
	$(PY) $(BIN2HEX) $< $@

clean:
	rm -f $(OUTS)

.PHONY: all clean
