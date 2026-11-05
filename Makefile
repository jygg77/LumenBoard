# iPhone X / iOS 16 rootless package. The privileged daemon owns the
# PosterBoard store writes; the Preferences bundle only submits bounded IPC requests.
ARCHS = arm64
TARGET = iphone:clang:16.5:16.0
THEOS_PACKAGE_SCHEME = rootless
THEOS_PLATFORM_DEB_COMPRESSION_TYPE = xz

include $(THEOS)/makefiles/common.mk

TOOL_NAME = lumenboardd
lumenboardd_FILES = Daemon/main.m Daemon/LBPosterBoardInstaller.m Daemon/LBPosterMediaBuilder.m Preferences/LBTendiesValidator.m Shared/LBPaths.m
lumenboardd_CFLAGS = -fobjc-arc -Wall -Wextra
lumenboardd_FRAMEWORKS = Foundation CoreFoundation UIKit AVFoundation CoreImage CoreGraphics
lumenboardd_LIBRARIES = z sqlite3
lumenboardd_INSTALL_PATH = /usr/libexec
include $(THEOS_MAKE_PATH)/tool.mk

SUBPROJECTS += Preferences
include $(THEOS_MAKE_PATH)/aggregate.mk

before-package::
	test -f $(THEOS_STAGING_DIR)/DEBIAN/postinst
	test -f $(THEOS_STAGING_DIR)/DEBIAN/prerm
	chmod 0755 $(THEOS_STAGING_DIR)/DEBIAN/postinst $(THEOS_STAGING_DIR)/DEBIAN/prerm
