# System 573 core - RTL unit test runner (Icarus Verilog)
#
#   make            run every testbench
#   make ds2401     run a single module's testbench
#   make clean

IV      := iverilog
VVP     := vvp
IVFLAGS := -g2005-sv -Wall
RTL     := ../rtl
BUILD   := build

TESTS := watchdog adc0834 m48t58 s573_nvram_loader s573_seccart_loader ds2401 adc0838 x76f100 x76f041 crc16 zs01 k573dio k573_mp3dec k573_mp3stream atapi irqdeliver s573_flash s573_flash_sdram s573_flash_image flash_nor s573_seccart s573_bus s573_io system573_top drivecheck s573_cdimg atapi_cdread

# Per-test RTL dependencies
SRC_watchdog      := $(RTL)/watchdog.v
SRC_adc0834       := $(RTL)/adc0834.v
SRC_adc0838       := $(RTL)/adc0838.v
SRC_m48t58        := $(RTL)/m48t58.v
SRC_s573_nvram_loader := $(RTL)/s573_nvram_loader.v $(RTL)/m48t58.v
SRC_s573_seccart_loader := $(RTL)/s573_seccart_loader.v
SRC_ds2401        := $(RTL)/ds2401.v
SRC_x76f100       := $(RTL)/x76f100.v
SRC_x76f041       := $(RTL)/x76f041.v
SRC_crc16         := $(RTL)/crc16.v
SRC_zs01          := $(RTL)/zs01.v
SRC_k573dio       := $(RTL)/k573dio.v $(RTL)/ds2401.v $(RTL)/k573_mp3stream.v $(RTL)/k573_mp3dec.v
SRC_k573_mp3dec   := $(RTL)/k573_mp3dec.v
SRC_k573_mp3stream := $(RTL)/k573_mp3stream.v $(RTL)/k573_mp3dec.v
SRC_atapi         := $(RTL)/atapi.v
SRC_irqdeliver    := $(RTL)/atapi.v
SRC_s573_cdimg    := $(RTL)/s573_cdimg.v
SRC_atapi_cdread  := $(RTL)/atapi.v $(RTL)/s573_cdimg.v
SRC_s573_flash    := $(RTL)/s573_flash.v $(RTL)/flash_nor.v
SRC_s573_flash_sdram := $(RTL)/s573_flash.v $(RTL)/flash_nor.v
SRC_s573_flash_image := $(RTL)/s573_flash.v $(RTL)/flash_nor.v
SRC_flash_nor     := $(RTL)/flash_nor.v
SRC_s573_seccart  := $(RTL)/s573_seccart.v $(RTL)/x76f100.v $(RTL)/x76f041.v $(RTL)/zs01.v $(RTL)/ds2401.v
SRC_s573_bus      := $(RTL)/s573_bus.v
SRC_s573_io       := $(RTL)/s573_io.v
SRC_system573_top := $(RTL)/system573_top.v $(RTL)/s573_bus.v $(RTL)/s573_io.v \
                     $(RTL)/watchdog.v $(RTL)/adc0834.v $(RTL)/m48t58.v $(RTL)/ds2401.v \
                     $(RTL)/s573_flash.v $(RTL)/flash_nor.v $(RTL)/s573_seccart.v $(RTL)/x76f100.v $(RTL)/x76f041.v $(RTL)/zs01.v \
                     $(RTL)/atapi.v $(RTL)/s573_cdimg.v $(RTL)/k573dio.v $(RTL)/k573_mp3stream.v $(RTL)/k573_mp3dec.v
SRC_drivecheck     := $(SRC_system573_top)

.PHONY: all clean secdata cddata $(TESTS)

# Derive the (gitignored, copyrighted) pnchmn2 security-cart $readmemh fixtures from
# the dump before the seccart test. No-op (test self-skips Part 2) if the dump is
# absent. Order-only so it always runs first for s573_seccart.
secdata:
	@sh gen_secdata.sh >/dev/null 2>&1 || true
s573_seccart: secdata
zs01: secdata

# Derive the (gitignored, copyrighted) CD-image $readmemh sector fixture from the
# hypbbc2p CHD before the end-to-end ATAPI read test. No-op (test self-skips to a
# synthetic ISO9660 sector) if the dump / chdman is absent.
cddata:
	@sh gen_cddata.sh >/dev/null 2>&1 || true
atapi_cdread: cddata

all:
	@fail=0; \
	for t in $(TESTS); do \
	  $(MAKE) -s $$t || fail=1; \
	done; \
	echo "-----------------------------------------"; \
	if [ $$fail -eq 0 ]; then echo "ALL TESTS PASSED"; \
	else echo "SOME TESTS FAILED"; exit 1; fi

# Template: compile tb_<name>.v + SRC_<name>, run, require "RESULT: PASS".
define RUN_TEST
$(1): | $(BUILD)
	@$(IV) $(IVFLAGS) -o $(BUILD)/$(1).vvp $(SRC_$(1)) tb_$(1).v 2> $(BUILD)/$(1).log; \
	out=$$$$($(VVP) $(BUILD)/$(1).vvp 2>> $(BUILD)/$(1).log); \
	echo "$$$$out" | grep -q "RESULT: PASS"; \
	if [ $$$$? -eq 0 ]; then \
	  echo "  PASS  $(1)"; \
	else \
	  echo "  FAIL  $(1)"; echo "$$$$out" | sed 's/^/        /'; \
	  echo "        (compile log: $(BUILD)/$(1).log)"; exit 1; \
	fi
endef
$(foreach t,$(TESTS),$(eval $(call RUN_TEST,$(t))))

$(BUILD):
	@mkdir -p $(BUILD)

clean:
	@rm -rf $(BUILD)
