# The sideload pipeline itself targets iOS 15. Xcode 27's libc++ headers no
# longer support deployment targets below iOS 15, so keep this compatibility
# shim aligned with the IPA minimum instead of inheriting the tweak's iOS 14
# jailbreak target.
TARGET := iphone:clang:latest:15.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := zxPluginsInject

$(TWEAK_NAME)_FILES := SideloadFix.xm ../fishhook/fishhook.c
$(TWEAK_NAME)_CFLAGS := -fobjc-arc -Os
$(TWEAK_NAME)_LOGOS_DEFAULT_GENERATOR := internal

include $(THEOS_MAKE_PATH)/tweak.mk
