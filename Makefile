export SYSROOT = $(THEOS)/sdks/$(or $(THEOS_SDK),iPhoneOS16.5.sdk)/
export TARGET = iphone:clang:latest:15.0
export FINALPACKAGE = 1
export DEBUG = 0
export THEOS_LEAN_AND_MEAN = 1
export THEOS_PLATFORM_DEB_COMPRESSION_TYPE = xz

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DashSplit
DashSplit_FILES = Sources/DashSplit.mm
DashSplit_FRAMEWORKS = UIKit Foundation QuartzCore
DashSplit_CFLAGS = -fobjc-arc

# Rootless install location, same as the other tweaks on this device.
DashSplit_INSTALL_PATH = /var/jb/Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk

# The "车载分屏" pane in the Settings app.
BUNDLE_NAME = DashSplitPref
DashSplitPref_FILES = Pref/DashSplitPref.mm
DashSplitPref_FRAMEWORKS = Foundation UIKit Preferences
DashSplitPref_CFLAGS = -fobjc-arc
DashSplitPref_INSTALL_PATH = /var/jb/Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	@echo "DashSplit staged at $(THEOS_STAGING_DIR)"
	mkdir -p "$(THEOS_STAGING_DIR)/var/jb/Library/PreferenceBundles/DashSplitPref.bundle"
	cp Pref/specs.plist "$(THEOS_STAGING_DIR)/var/jb/Library/PreferenceBundles/DashSplitPref.bundle/specs.plist"
	mkdir -p "$(THEOS_STAGING_DIR)/var/jb/Library/PreferenceLoader/Preferences"
	cp Pref/entry.plist "$(THEOS_STAGING_DIR)/var/jb/Library/PreferenceLoader/Preferences/DashSplit.plist"
