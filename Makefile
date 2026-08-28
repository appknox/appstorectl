TARGET := iphone:clang:16.5:14.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

# All three ship in one package: the tweak is inert unless the CLI arms it, so installing
# either alone is a confusing half-state.
#
# decrypt/ is a separate binary rather than more files in cli/ because it needs entitlements
# the CLI must not carry: task_for_pid-allow, com.apple.private.cs.debugger and no-sandbox.
# Merging them would hand the store client debugger rights it has no use for, to save one
# posix_spawn. See decrypt/entitlements.plist.
SUBPROJECTS = cli tweak decrypt

include $(THEOS_MAKE_PATH)/aggregate.mk

# PassbookUIService is launch-on-demand and holds the old dylib until it exits, so bounce it after
# installing. A full respring is not needed — the tweak only injects there.
after-install::
	install.exec "killall -9 PassbookUIService 2>/dev/null; true"
