# Subprojects do not inherit these from the aggregate — see cli/Makefile.
TARGET := iphone:clang:16.5:14.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AutoConfirmSheet

AutoConfirmSheet_FILES = Tweak.x
AutoConfirmSheet_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
AutoConfirmSheet_FRAMEWORKS = Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
