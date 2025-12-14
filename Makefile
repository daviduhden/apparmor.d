# Install AppArmor abstractions, profiles, and the sync helper, then optionally
# load them. Copies tor abstraction and service profiles into /etc/apparmor.d
# (respecting DESTDIR/PREFIX), ships sync-profiles in /usr/local/bin for
# refreshing upstream profiles in enforce mode, and provides 'make load' and
# 'make check' (warnings treated as errors) via apparmor_parser.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

PREFIX ?=
DESTDIR ?=
APPARMOR_DIR ?= $(DESTDIR)$(PREFIX)/etc/apparmor.d
BINDIR ?= $(DESTDIR)$(PREFIX)/usr/local/bin
APPARMOR_PARSER ?= apparmor_parser
APPARMOR_FLAGS ?= -r -T -W
APPARMOR_CHECK_FLAGS ?= -T -W
ABSTRACTIONS_DIR := $(APPARMOR_DIR)/abstractions
ABSTRACTIONS := abstractions/tor 
PROFILES := usr.sbin.tor usr.bin.i2pd usr.bin.monerod usr.bin.radicale usr.sbin.opendkim 
INFO := ==> 

.PHONY: install
install:
	@echo "$(INFO) Creating target directories: $(ABSTRACTIONS_DIR) $(BINDIR)"
	install -d $(ABSTRACTIONS_DIR) $(BINDIR)
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
	@echo "$(INFO) Removing legacy symlink if present: $(APPARMOR_DIR)/system_tor"
	@rm -f $(APPARMOR_DIR)/system_tor # clean legacy symlink/name if present
	@echo "$(INFO) Installing sync helper -> $(BINDIR)/sync-profiles"
	install -m 0755 sync-profiles.pl $(BINDIR)/sync-profiles
	@echo "$(INFO) Install complete"

.PHONY: load
load: install
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
check:
	@command -v $(APPARMOR_PARSER) >/dev/null || { echo "$(INFO) apparmor_parser not found"; exit 1; }
	@for f in $(PROFILES); do \
		if [ -f $$f ]; then \
			echo "$(INFO) Syntax check $$f"; \
			$(APPARMOR_PARSER) $(APPARMOR_CHECK_FLAGS) $$f; \
		else \
			echo "$(INFO) Skipping missing $$f"; \
		fi; \
	done
