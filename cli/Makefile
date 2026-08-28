# Subprojects do not inherit these from the aggregate — common.mk resets them, and the default
# target is armv7, which fails to link against a modern SDK.
TARGET := iphone:clang:16.5:14.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TOOL_NAME = appstorectl authpref

# The service gate is a single entitlement: com.apple.itunesstored.private. Without it every call
# into appstored returns ASDErrorDomain 505 "Not entitled for this service."
appstorectl_FILES = appstorectl.m
appstorectl_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
appstorectl_FRAMEWORKS = Foundation
appstorectl_CODESIGN_FLAGS = -Sentitlements.plist
appstorectl_INSTALL_PATH = /usr/bin

# Non-ARC on purpose: the private reply blocks here have undocumented arity, and ARC will retain a
# scalar argument slot as if it were an object. See ASDPrivate.h.
authpref_FILES = authpref.m
authpref_CFLAGS = -fno-objc-arc -Wno-deprecated-declarations
authpref_FRAMEWORKS = Foundation
authpref_CODESIGN_FLAGS = -Sentitlements.plist
authpref_INSTALL_PATH = /usr/bin

include $(THEOS_MAKE_PATH)/tool.mk
