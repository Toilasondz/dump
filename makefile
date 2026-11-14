ARCHS = arm64
TARGET := iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VSDumpHeaders

VSDumpHeaders_FILES = VSDumpHeaders.m
VSDumpHeaders_CFLAGS = -fobjc-arc
VSDumpHeaders_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

# Thay VideoStar bằng tên tiến trình thật của app (tên executable).
after-install::
	install.exec "killall -9 VideoStar" || true
