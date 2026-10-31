################################################################################
#
# aic8800
#
################################################################################

AIC8800_VERSION = fce88024ed40279def034e203128e0892fdbcac3
AIC8800_SITE = $(call github,radxa-pkg,aic8800,$(AIC8800_VERSION))
# Radxa declares src/* (including firmware) GPL-2; packaging is GPL-3+.
AIC8800_LICENSE = GPL-2.0, GPL-3.0+
AIC8800_LICENSE_FILES = LICENSE debian/copyright

AIC8800_DRIVERS = src/USB/driver_fw/drivers
AIC8800_MODULE_SUBDIRS = $(AIC8800_DRIVERS)/aic8800 $(AIC8800_DRIVERS)/aic_btusb

# Radxa's own Debian patch series (kernel API fixes, BlueZ HCI for aic_btusb).
# Skipped: the USB firmware-path and log-level patches do not apply to the
# CRLF sources; the default /lib/firmware/aic8800D80 path is used instead.
AIC8800_SKIPPED_PATCHES = fix-usb-firmware-path.patch fix-Lower-the-debugging-log-level.patch

define AIC8800_APPLY_DEBIAN_PATCHES
	for p in $$(grep -v -x $(addprefix -e ,$(AIC8800_SKIPPED_PATCHES)) $(@D)/debian/patches/series); do \
		patch -d $(@D) -p1 -l -s < $(@D)/debian/patches/$$p || exit 1; \
	done
endef
AIC8800_POST_PATCH_HOOKS += AIC8800_APPLY_DEBIAN_PATCHES

define AIC8800_INSTALL_TARGET_CMDS
	mkdir -p $(TARGET_DIR)/lib/firmware/aic8800D80
	cp $(@D)/src/USB/driver_fw/fw/aic8800D80/* $(TARGET_DIR)/lib/firmware/aic8800D80/
endef

$(eval $(kernel-module))
$(eval $(generic-package))
