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

OUTS := bootsec.bin iosys_stub.bin card.bin card_64k.bin card.hex

all: $(OUTS)
	@echo
	@echo "Built:"
	@ls -l $(OUTS)

bootsec.bin: bootsec.asm
	$(NASM) -f bin -o $@ $<

iosys_stub.bin: iosys_stub.asm
	$(NASM) -f bin -o $@ $<

card.bin: bootsec.bin iosys_stub.bin
	cat bootsec.bin iosys_stub.bin > $@

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
