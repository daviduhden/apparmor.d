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
APPARMOR_DIR ?= $(DESTDIR)$(PREFIX)/etc/apparmor.d
BINDIR ?= $(DESTDIR)$(PREFIX)/usr/local/bin
APPARMOR_PARSER ?= apparmor_parser
APPARMOR_FLAGS ?= -r -T -W
APPARMOR_CHECK_FLAGS ?= -T -W -K
ABSTRACTIONS_DIR := $(APPARMOR_DIR)/abstractions
ABSTRACTIONS := abstractions/tor 
PROFILES := usr.sbin.tor usr.bin.i2pd usr.bin.monerod usr.bin.radicale usr.sbin.opendkim 
PROFILE_NAMES := tor i2pd monerod radicale opendkim 
INFO := ==> 

.PHONY: install help unload-profiles load check uninstall
install:
	@echo "$(INFO) Creating target directories: $(ABSTRACTIONS_DIR) $(BINDIR)"
	install -d $(ABSTRACTIONS_DIR) $(BINDIR)
	@echo "$(INFO) Ensuring local override directory: $(APPARMOR_DIR)/local"
	install -d $(APPARMOR_DIR)/local
	@for f in $(ABSTRACTIONS); do \
		dest=$(ABSTRACTIONS_DIR)/$${f#abstractions/}; \
		echo "$(INFO) Installing abstraction $$f -> $$dest"; \
		install -d $$(dirname $$dest); \
		install -m 0644 $$f $$dest; \
	done
	@for f in $(PROFILES); do \
		dest=$(APPARMOR_DIR)/$$f; \
		echo "$(INFO) Installing profile $$f -> $$dest"; \
		install -d $$(dirname $$dest); \
		install -m 0644 $$f $$dest; \
	done
	@for f in $(PROFILES); do \
		stub=$(APPARMOR_DIR)/local/$$f; \
		if [ ! -f $$stub ]; then \
			echo "$(INFO) Creating stub local/$$f"; \
			install -d $$(dirname $$stub); \
			install -m 0644 /dev/null $$stub; \
		fi; \
	done
	@rm -f $(APPARMOR_DIR)/system_tor
	@echo "$(INFO) Installing helper scripts..."
	install -m 0755 scripts/sync-profiles.pl $(BINDIR)/sync-profiles
	install -m 0755 scripts/enforce-complain-toggle.pl $(BINDIR)/enforce-complain-toggle
	@echo "$(INFO) Install complete"


.PHONY: help
help:
	@echo "$(INFO) Usage: make [target] [VARIABLE=value]"
	@echo ""
	@echo "Targets:"
	@echo "  install            Install abstractions, profiles and helper scripts"
	@echo "  load               Install and load profiles using $(APPARMOR_PARSER)"
	@echo "  check              Syntax-check profiles (warnings treated as errors)"
	@echo "  unload-profiles    Unload installed profiles by name"
	@echo "  uninstall          Remove installed profiles, stubs and helper scripts"
	@echo "  help               Show this help"
	@echo ""
	@echo "Variables:"
	@echo "  PREFIX             Install prefix (default: $(PREFIX))"
	@echo "  DESTDIR            Destination directory (default empty)"
	@echo "  APPARMOR_PARSER    Path to apparmor_parser (default: $(APPARMOR_PARSER))"



.PHONY: unload-profiles
unload-profiles:
	@for name in $(PROFILE_NAMES); do \
		$(APPARMOR_PARSER) -R $$name >/dev/null 2>&1 || true; \
	done


.PHONY: uninstall
uninstall:
	@echo "$(INFO) Removing helper scripts -> $(BINDIR)/sync-profiles"
	@rm -f $(BINDIR)/sync-profiles $(BINDIR)/enforce-complain-toggle || true
	@echo "$(INFO) Removing profiles from $(APPARMOR_DIR)"
	@for f in $(PROFILES); do \
		rm -f $(APPARMOR_DIR)/$$f || true; \
	done
	@echo "$(INFO) Removing local stubs"
	@for f in $(PROFILES); do \
		rm -f $(APPARMOR_DIR)/local/$$f || true; \
	done
	@echo "$(INFO) Removing abstractions"
	@for f in $(ABSTRACTIONS); do \
		rm -f $(ABSTRACTIONS_DIR)/$${f#abstractions/} || true; \
	done
	@echo "$(INFO) Cleanup empty directories (may fail if not empty)"
	-rmdir --ignore-fail-on-non-empty $(APPARMOR_DIR)/local 2>/dev/null || true
	-rmdir --ignore-fail-on-non-empty $(ABSTRACTIONS_DIR) 2>/dev/null || true

.PHONY: load
load: install unload-profiles
	@command -v $(APPARMOR_PARSER) >/dev/null || { echo "$(INFO) apparmor_parser not found"; exit 1; }
	@for f in $(PROFILES); do \
		src=$(APPARMOR_DIR)/$$f; \
		if [ -f $$src ]; then \
			echo "$(INFO) Loading $$src"; \
			$(APPARMOR_PARSER) $(APPARMOR_FLAGS) $$src; \
		else \
			echo "$(INFO) Skipping missing profile $$src"; \
		fi; \
	done

.PHONY: check
check: install unload-profiles
	@command -v $(APPARMOR_PARSER) >/dev/null || { echo "$(INFO) apparmor_parser not found"; exit 1; }
	@tmp=$$(mktemp -d /tmp/apparmor-check.XXXXXX); \
	trap 'rm -rf $$tmp' EXIT INT TERM; \
	install -d $$tmp/abstractions $$tmp/local; \
	cp abstractions/tor $$tmp/abstractions/; \
	for f in $(PROFILES); do \
		install -d $$(dirname $$tmp/$$f); \
		install -m 0644 $$f $$tmp/$$f; \
		touch $$tmp/local/$$f; \
	done; \
	for f in $(PROFILES); do \
		src=$$tmp/$$f; \
		echo "$(INFO) Syntax check $$src"; \
		$(APPARMOR_PARSER) $(APPARMOR_CHECK_FLAGS) -I $$tmp $$src; \
	done
