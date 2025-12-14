# Install AppArmor abstractions and local profiles plus the sync helper.
# Copies tor abstraction and service profiles into /etc/apparmor.d (respecting
# DESTDIR/PREFIX) and ships sync-profiles in /usr/local/bin for refreshing
# upstream profiles in enforce mode.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

PREFIX ?=
DESTDIR ?=
APPARMOR_DIR ?= $(DESTDIR)$(PREFIX)/etc/apparmor.d
BINDIR ?= $(DESTDIR)$(PREFIX)/usr/local/bin
ABSTRACTIONS_DIR := $(APPARMOR_DIR)/abstractions
ABSTRACTIONS := abstractions/tor 
PROFILES := usr.sbin.tor usr.bin.i2pd usr.bin.monerod usr.bin.radicale usr.sbin.opendkim 

.PHONY: install
install:
	install -d $(ABSTRACTIONS_DIR) $(BINDIR)
	@for f in $(ABSTRACTIONS); do \
		dest=$(ABSTRACTIONS_DIR)/$${f#abstractions/}; \
		install -d $$(dirname $$dest); \
		install -m 0644 $$f $$dest; \
	done
	@rm -f $(APPARMOR_DIR)/system_tor # clean legacy symlink/name if present
	install -m 0755 sync-profiles.pl $(BINDIR)/sync-profiles
