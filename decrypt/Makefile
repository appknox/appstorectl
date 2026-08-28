ifneq ($(filter test-host,$(MAKECMDGOALS)),)
  .PHONY: test-host
  HOST_TEST_BIN ?= /tmp/appstorectl-decrypt-macho-tests
  HOST_TEST_CFLAGS ?= -std=c11 -Wall -Wextra -Werror -pedantic \
	-fsanitize=undefined -fno-omit-frame-pointer

test-host:
	clang $(HOST_TEST_CFLAGS) -I. \
		macho.c output.c log.c tests/test_macho.c -o $(HOST_TEST_BIN)
	$(HOST_TEST_BIN)
else
  TARGET := iphone:clang:16.5:14.0
  ARCHS = arm64
  THEOS_PACKAGE_SCHEME = rootless

  include $(THEOS)/makefiles/common.mk

  TOOL_NAME = appstorectl-decrypt
  appstorectl-decrypt_FILES = main.c decrypt.c process.c runtime.c remote.c macho.c output.c log.c
  appstorectl-decrypt_CFLAGS = -O2 -Werror -Wno-deprecated-declarations
  appstorectl-decrypt_CODESIGN_FLAGS = -Sentitlements.plist
  appstorectl-decrypt_INSTALL_PATH = /usr/bin

  include $(THEOS_MAKE_PATH)/tool.mk
endif
