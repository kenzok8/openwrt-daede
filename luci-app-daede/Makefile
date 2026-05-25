# SPDX-License-Identifier: Apache-2.0
#
# Copyright (C) 2023 ImmortalWrt.org

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-daede
PKG_VERSION:=1.1
PKG_RELEASE:=1

LUCI_TITLE:=LuCI app for daede dashboard
LUCI_DEPENDS:=+PACKAGE_$(PKG_NAME)_dae:dae +PACKAGE_$(PKG_NAME)_daed:daed
LUCI_PKGARCH:=all

define Package/$(PKG_NAME)/config
	choice
		prompt "Backend dependency"
		default PACKAGE_$(PKG_NAME)_daed
		help
			Select which backend package luci-app-daede should pull in by default.

	config PACKAGE_$(PKG_NAME)_daed
		bool "daed backend"

	config PACKAGE_$(PKG_NAME)_dae
		bool "dae backend"

	endchoice
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
