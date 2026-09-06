TARGET := iphone:clang:16.5:14.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

# tweak/ is deliberately NOT built into this package. The buy params the CLI now sends stop the
# store raising a confirmation sheet at all, so AutoConfirmSheet had nothing left to dismiss on the
# default path, and shipping an injected dylib into PassbookUIService that never fires is worse than
# not shipping it. The source stays in the tree: --force-dismiss still exists and still arms the
# flag, so putting `tweak` back on this line is all it takes to restore the old behaviour.
# See docs/GATES.md gate 3.
#
# decrypt/ is a separate binary rather than more files in cli/ because it needs entitlements
# the CLI must not carry: task_for_pid-allow, com.apple.private.cs.debugger and no-sandbox.
# Merging them would hand the store client debugger rights it has no use for, to save one
# posix_spawn. See decrypt/entitlements.plist.
SUBPROJECTS = cli decrypt

include $(THEOS_MAKE_PATH)/aggregate.mk
