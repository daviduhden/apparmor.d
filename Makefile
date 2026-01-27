# Install AppArmor abstractions, profiles, and the sync helper, then optionally
# load them. Copies tor abstraction and service profiles into /etc/apparmor.d
# (respecting DESTDIR/PREFIX), ships sync-profiles in /usr/local/bin for
# refreshing upstream profiles in enforce mode, and provides 'make load' and
# 'make check' (warnings treated as errors) via apparmor_parser.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

PREFIX ?= /usr
DESTDIR ?=
INSTALL ?= install
# Install profiles under /etc/apparmor.d (respect DESTDIR when set)
APPARMOR_DIR ?= $(DESTDIR)/etc/apparmor.d
# Helper scripts go to /usr/local/bin under DESTDIR
BINDIR ?= $(DESTDIR)/usr/local/bin
APPARMOR_PARSER ?= apparmor_parser
APPARMOR_FLAGS ?= -r -T -W
APPARMOR_CHECK_FLAGS ?= -T -W -K
ABSTRACTIONS_DIR := $(APPARMOR_DIR)/abstractions
ABSTRACTIONS := abstractions/tor
PROFILES := usr.sbin.tor usr.bin.i2pd usr.bin.monerod usr.bin.radicale usr.sbin.opendkim
PROFILE_NAMES := tor i2pd monerod radicale opendkim
INFO := ==>
SCRIPTS := scripts/enforce-complain-toggle.pl scripts/merge-dupe-rules.pl

.PHONY: all clean install install-scripts help unload-profiles uninstall load check test

all: install

clean:
	@echo "$(INFO) Nothing to clean"

install:
	@echo "$(INFO) Creating target directories: $(APPARMOR_DIR) $(ABSTRACTIONS_DIR) $(BINDIR)" && install -d $(APPARMOR_DIR) $(ABSTRACTIONS_DIR) $(BINDIR) $(APPARMOR_DIR)/local
	@for f in $(ABSTRACTIONS); do dest=$(ABSTRACTIONS_DIR)/$${f#abstractions/}; [ -f $$f ] && { echo "$(INFO) Installing abstraction $$f -> $$dest"; install -d $$(dirname $$dest); install -m 0644 $$f $$dest; } || echo "$(INFO) Warning: abstraction $$f not found, skipping"; done
	@for f in $(PROFILES); do dest=$(APPARMOR_DIR)/$$f; [ -f $$f ] && { echo "$(INFO) Installing profile $$f -> $$dest"; install -d $$(dirname $$dest); install -m 0644 $$f $$dest; } || echo "$(INFO) Warning: profile $$f not found, skipping"; done
	@for f in $(PROFILES); do stub=$(APPARMOR_DIR)/local/$$f; [ -f $$stub ] || { echo "$(INFO) Creating stub local/$$f"; install -d $$(dirname $$stub); install -m 0644 /dev/null $$stub; }; done && rm -f $(APPARMOR_DIR)/system_tor
	@for s in $(SCRIPTS); do if [ -f $$s ]; then name=$$(basename $$s .pl); dest=$(BINDIR)/$$name; echo "$(INFO) Installing script $$s -> $$dest"; install -d $$(dirname $$dest); install -m 0755 $$s $$dest; else echo "$(INFO) Warning: script $$s not found, skipping"; fi; done && echo "$(INFO) Install complete"

install-scripts:
	@install -d $(BINDIR) && for s in $(SCRIPTS); do if [ -f $$s ]; then name=$$(basename $$s .pl); dest=$(BINDIR)/$$name; echo "$(INFO) Installing script $$s -> $$dest"; install -m 0755 $$s $$dest; else echo "$(INFO) Warning: script $$s not found, skipping"; fi; done && echo "$(INFO) Scripts installed"

help:
	@printf "$(INFO) Usage: make [target] [VARIABLE=value]\n\nTargets:\n  all                Install abstractions, profiles and helper scripts\n  install            Install abstractions, profiles and helper scripts\n  install-scripts    Install helper scripts only\n  load               Install and load profiles using $(APPARMOR_PARSER)\n  check              Syntax-check profiles (warnings treated as errors)\n  unload-profiles    Unload installed profiles by name\n  uninstall          Remove installed profiles, stubs and helper scripts\n  clean              No-op clean target\n  test               Placeholder for tests\n  help               Show this help\n\nVariables:\n  PREFIX             Install prefix (default: $(PREFIX))\n  DESTDIR            Destination directory (default empty)\n  APPARMOR_PARSER    Path to apparmor_parser (default: $(APPARMOR_PARSER))\n  APPARMOR_FLAGS     Flags for loading profiles (default: '$(APPARMOR_FLAGS)')\n  APPARMOR_CHECK_FLAGS Flags for checking profiles (default: '$(APPARMOR_CHECK_FLAGS)')\n  BINDIR             Directory for helper scripts (default: $(BINDIR))\n"

unload-profiles:
	@for name in $(PROFILE_NAMES); do $(APPARMOR_PARSER) -R $$name >/dev/null 2>&1 || true; done

uninstall:
	@for s in $(SCRIPTS); do name=$$(basename $$s .pl); echo "$(INFO) Removing $(BINDIR)/$$name"; rm -f $(BINDIR)/$$name || true; done
	@for f in $(PROFILES); do echo "$(INFO) Removing $(APPARMOR_DIR)/$$f"; rm -f $(APPARMOR_DIR)/$$f $(APPARMOR_DIR)/local/$$f || true; done
	@for f in $(ABSTRACTIONS); do echo "$(INFO) Removing $(ABSTRACTIONS_DIR)/$${f#abstractions/}"; rm -f $(ABSTRACTIONS_DIR)/$${f#abstractions/} || true; done
	@rmdir --ignore-fail-on-non-empty $(APPARMOR_DIR)/local $(ABSTRACTIONS_DIR) 2>/dev/null || true
	@echo "$(INFO) Uninstall complete"

load: install unload-profiles
	@command -v $(APPARMOR_PARSER) >/dev/null || { echo "$(INFO) apparmor_parser not found"; exit 1; }; for f in $(PROFILES); do src=$(APPARMOR_DIR)/$$f; if [ -f $$src ]; then echo "$(INFO) Loading $$src"; $(APPARMOR_PARSER) $(APPARMOR_FLAGS) $$src; else echo "$(INFO) Skipping missing profile $$src"; fi; done

check: install unload-profiles
	@command -v $(APPARMOR_PARSER) >/dev/null || { echo "$(INFO) apparmor_parser not found"; exit 1; }; tmp=$$(mktemp -d /tmp/apparmor-check.XXXXXX) && trap 'rm -rf $$tmp' EXIT INT TERM && install -d $$tmp/abstractions $$tmp/local && cp abstractions/tor $$tmp/abstractions/ && for f in $(PROFILES); do install -d $$(dirname $$tmp/$$f); install -m 0644 $$f $$tmp/$$f; touch $$tmp/local/$$f; done && for f in $(PROFILES); do src=$$tmp/$$f; echo "$(INFO) Syntax check $$src"; $(APPARMOR_PARSER) $(APPARMOR_CHECK_FLAGS) -I $$tmp $$src; done

test:
	@echo "$(INFO) No automated tests defined"