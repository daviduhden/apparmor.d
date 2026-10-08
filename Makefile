# Install AppArmor abstractions, profiles, and the helper scripts, then
# optionally load them. Copies the tor abstraction and service profiles into
# /etc/apparmor.d (respecting DESTDIR), diverts distro copies of files we
# replace with dpkg-divert, installs the helper scripts under
# $(PREFIX)/local/bin, and provides 'make load' and 'make check'
# (warnings treated as errors) via apparmor_parser.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

PREFIX ?= /usr
DESTDIR ?=
INSTALL ?= install
# Install profiles under /etc/apparmor.d (respect DESTDIR when set)
APPARMOR_DIR ?= $(DESTDIR)/etc/apparmor.d
# Helper scripts go to $(PREFIX)/local/bin under DESTDIR (default /usr/local/bin)
BINDIR ?= $(DESTDIR)$(PREFIX)/local/bin
APPARMOR_PARSER ?= apparmor_parser
APPARMOR_FLAGS ?= -r -T -W
# -Q: compile without loading into the kernel; -K: do not read/write the cache.
# --Werror makes the syntax check fail on parser warnings, as documented.
APPARMOR_CHECK_FLAGS ?= -Q -K --Werror
ABSTRACTIONS_DIR := $(APPARMOR_DIR)/abstractions
ABSTRACTIONS := abstractions/tor
PROFILES := usr.sbin.tor usr.bin.i2pd usr.bin.monerod usr.bin.monero-lws-daemon usr.bin.radicale usr.sbin.opendkim usr.bin.xd-torrent usr.bin.fail2ban-server
PROFILE_NAMES := tor i2pd monerod monero-lws-daemon radicale opendkim xd-torrent fail2ban-server
INFO := ==>
SCRIPTS := scripts/enforce-complain-toggle.pl scripts/merge-dupe-rules.pl

# Files under /etc/apparmor.d that are also shipped by Debian packages
# (i2pd -> usr.bin.i2pd, tor -> system_tor and abstractions/tor). Instead of
# overwriting or deleting the distro copies, we rename them with dpkg-divert
# into DIVERT_DIR and install ours in the canonical location. This keeps apt
# upgrades from clobbering the shipped profiles and preserves the originals
# so they can be restored by 'make uninstall'.
#
# DIVERT_DIR must be a subdirectory of APPARMOR_DIR: the AppArmor loader
# scans only the top level of /etc/apparmor.d (subdirectories are skipped),
# so the diverted copies are never loaded.
DIVERT ?= $(if $(DESTDIR),no,yes)
DIVERT_FILES := usr.bin.i2pd system_tor abstractions/tor
DIVERT_DIR ?= $(APPARMOR_DIR)/distrib
DPKG_DIVERT ?= dpkg-divert

.PHONY: all clean install install-scripts help unload-profiles uninstall load check test

all: install

clean:
	@echo "$(INFO) Nothing to clean"

install:
	@echo "$(INFO) Creating target directories: $(APPARMOR_DIR) $(ABSTRACTIONS_DIR) $(BINDIR)" && $(INSTALL) -d $(APPARMOR_DIR) $(ABSTRACTIONS_DIR) $(BINDIR) $(APPARMOR_DIR)/local
	@if [ "$(DIVERT)" = "yes" ] && command -v $(DPKG_DIVERT) >/dev/null 2>&1; then \
		for f in $(DIVERT_FILES); do \
			src=$(APPARMOR_DIR)/$$f; dst=$(DIVERT_DIR)/$$f; \
			$(INSTALL) -d $$(dirname $$dst); \
			if [ -n "$$($(DPKG_DIVERT) --listpackage $$src 2>/dev/null)" ]; then \
				echo "$(INFO) Diversion already present: $$src"; \
			elif [ -e "$$src" ]; then \
				echo "$(INFO) Diverting distro file $$src -> $$dst"; \
				$(DPKG_DIVERT) --local --divert $$dst --rename $$src || \
					echo "$(INFO) Warning: could not divert $$src"; \
			else \
				echo "$(INFO) Recording diversion for absent $$src -> $$dst"; \
				$(DPKG_DIVERT) --local --divert $$dst --no-rename $$src || \
					echo "$(INFO) Warning: could not divert $$src"; \
			fi; \
		done; \
	else \
		echo "$(INFO) dpkg-divert disabled or unavailable; distro profiles not diverted"; \
	fi
	@for f in $(ABSTRACTIONS); do dest=$(ABSTRACTIONS_DIR)/$${f#abstractions/}; [ -f $$f ] && { echo "$(INFO) Installing abstraction $$f -> $$dest"; $(INSTALL) -d $$(dirname $$dest); $(INSTALL) -m 0644 $$f $$dest; } || echo "$(INFO) Warning: abstraction $$f not found, skipping"; done
	@for f in $(PROFILES); do dest=$(APPARMOR_DIR)/$$f; [ -f $$f ] && { echo "$(INFO) Installing profile $$f -> $$dest"; $(INSTALL) -d $$(dirname $$dest); $(INSTALL) -m 0644 $$f $$dest; } || echo "$(INFO) Warning: profile $$f not found, skipping"; done
	@for f in $(PROFILES); do stub=$(APPARMOR_DIR)/local/$$f; [ -f $$stub ] || { echo "$(INFO) Creating stub local/$$f"; $(INSTALL) -d $$(dirname $$stub); $(INSTALL) -m 0644 /dev/null $$stub; }; done
	@for s in $(SCRIPTS); do if [ -f $$s ]; then name=$$(basename $$s .pl); dest=$(BINDIR)/$$name; echo "$(INFO) Installing script $$s -> $$dest"; $(INSTALL) -d $$(dirname $$dest); $(INSTALL) -m 0755 $$s $$dest; else echo "$(INFO) Warning: script $$s not found, skipping"; fi; done && echo "$(INFO) Install complete"

install-scripts:
	@$(INSTALL) -d $(BINDIR) && for s in $(SCRIPTS); do if [ -f $$s ]; then name=$$(basename $$s .pl); dest=$(BINDIR)/$$name; echo "$(INFO) Installing script $$s -> $$dest"; $(INSTALL) -m 0755 $$s $$dest; else echo "$(INFO) Warning: script $$s not found, skipping"; fi; done && echo "$(INFO) Scripts installed"

help:
	@printf "$(INFO) Usage: make [target] [VARIABLE=value]\n\nTargets:\n  all                Install abstractions, profiles and helper scripts\n  install            Install abstractions, profiles and helper scripts\n  install-scripts    Install helper scripts only\n  load               Install and load profiles using $(APPARMOR_PARSER)\n  check              Syntax-check profiles (warnings treated as errors)\n  unload-profiles    Unload installed profiles by name\n  uninstall          Remove installed profiles, stubs and helper scripts\n  clean              No-op clean target\n  test               Placeholder for tests\n  help               Show this help\n\nVariables:\n  PREFIX             Install prefix (default: $(PREFIX))\n  DESTDIR            Destination directory (default empty)\n  APPARMOR_PARSER    Path to apparmor_parser (default: $(APPARMOR_PARSER))\n  APPARMOR_FLAGS     Flags for loading profiles (default: '$(APPARMOR_FLAGS)')\n  APPARMOR_CHECK_FLAGS Flags for checking profiles (default: '$(APPARMOR_CHECK_FLAGS)')\n  BINDIR             Directory for helper scripts (default: $(BINDIR))\n  DIVERT             Redirect distro profiles with dpkg-divert (default: $(DIVERT))\n  DIVERT_DIR         Directory holding diverted distro files (default: $(DIVERT_DIR))\n"

unload-profiles:
	@for name in $(PROFILE_NAMES); do $(APPARMOR_PARSER) -R $$name >/dev/null 2>&1 || true; done

uninstall:
	@for s in $(SCRIPTS); do name=$$(basename $$s .pl); echo "$(INFO) Removing $(BINDIR)/$$name"; rm -f $(BINDIR)/$$name || true; done
	@for f in $(PROFILES); do echo "$(INFO) Removing $(APPARMOR_DIR)/$$f"; rm -f $(APPARMOR_DIR)/$$f $(APPARMOR_DIR)/local/$$f || true; done
	@for f in $(ABSTRACTIONS); do echo "$(INFO) Removing $(ABSTRACTIONS_DIR)/$${f#abstractions/}"; rm -f $(ABSTRACTIONS_DIR)/$${f#abstractions/} || true; done
	@if [ "$(DIVERT)" = "yes" ] && command -v $(DPKG_DIVERT) >/dev/null 2>&1; then \
		for f in $(DIVERT_FILES); do \
			src=$(APPARMOR_DIR)/$$f; dst=$(DIVERT_DIR)/$$f; \
			if [ -n "$$($(DPKG_DIVERT) --listpackage $$src 2>/dev/null)" ]; then \
				if $(DPKG_DIVERT) --local --divert $$dst --rename --remove $$src 2>/dev/null; then \
					echo "$(INFO) Removed diversion for $$src (restored from $$dst)"; \
				else \
					echo "$(INFO) Warning: could not remove diversion for $$src"; \
				fi; \
			fi; \
		done; \
		find $(DIVERT_DIR) -depth -type d -empty -delete 2>/dev/null || true; \
	fi
	@rmdir --ignore-fail-on-non-empty $(APPARMOR_DIR)/local $(ABSTRACTIONS_DIR) 2>/dev/null || true
	@echo "$(INFO) Uninstall complete"

load: install unload-profiles
	@command -v $(APPARMOR_PARSER) >/dev/null || { echo "$(INFO) apparmor_parser not found"; exit 1; }; for f in $(PROFILES); do src=$(APPARMOR_DIR)/$$f; if [ -f $$src ]; then echo "$(INFO) Loading $$src"; $(APPARMOR_PARSER) $(APPARMOR_FLAGS) $$src; else echo "$(INFO) Skipping missing profile $$src"; fi; done

check:
	@command -v $(APPARMOR_PARSER) >/dev/null || { echo "$(INFO) apparmor_parser not found"; exit 1; }; tmp=$$(mktemp -d /tmp/apparmor-check.XXXXXX) && trap 'rm -rf $$tmp' EXIT INT TERM && $(INSTALL) -d $$tmp/abstractions $$tmp/local && { [ ! -f abstractions/tor ] || cp abstractions/tor $$tmp/abstractions/; } && for f in $(PROFILES); do $(INSTALL) -d $$(dirname $$tmp/$$f); $(INSTALL) -m 0644 $$f $$tmp/$$f; touch $$tmp/local/$$f; done && for f in $(PROFILES); do src=$$tmp/$$f; echo "$(INFO) Syntax check $$src"; $(APPARMOR_PARSER) $(APPARMOR_CHECK_FLAGS) -I $$tmp $$src; done

test:
	@echo "$(INFO) No automated tests defined"
