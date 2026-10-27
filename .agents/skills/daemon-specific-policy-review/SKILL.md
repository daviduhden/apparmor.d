---
name: daemon-specific-policy-review
description: Review the shipped AppArmor policy for Tor, i2pd, monerod, monero-lws, Radicale, OpenDKIM, Fail2Ban, and xd-torrent. Use when changing or auditing one of these profiles or diagnosing a denial for those daemons.
---

# Daemon-specific policy review

## Activation conditions

Use this skill when the task concerns one of the eight shipped daemons, their
paths, ports, sockets, capabilities, or a denial reported for them. Pair it with
`apparmor-policy-validation` for the validation workflow.

## Ground rules

- The repository defines policy, not deployment. The service user, unit file,
  port numbers, and data directories are not declared here. Confirm them from
  the package or unit on the target; never assume `root`, a port, or a path.
- A path rule only applies to the path as resolved. Symlinked binaries and
  directories need the final path (or all real paths) in the attachment.
- `owner` is a UID check, not a statement about who installed the file.
- All eight profiles currently declare `enforce`; none ships a complain or
  disabled variant. See `apparmor-installation-and-modes` before changing mode.
- The profiles use `abi <abi/4.0>`; older parsers will fail or warn.

## Per-daemon matrix

### Tor: `usr.sbin.tor`, `abstractions/tor`

- Attachment: `/{usr/,}{,s}bin/tor` (covers `/usr/bin/tor`, `/usr/sbin/tor`,
  and the `/bin`/`/sbin` equivalents).
- Includes: `base`, `nameservice`, `ssl_certs`, `tor`; local
  `local/usr.sbin.tor`.
- Capabilities: `net_bind_service` in the profile, plus `chown`,
  `dac_read_search`, `fowner`, `fsetid`, `setgid`, `setuid` from the
  abstraction.
- Data: `owner /var/lib/tor/**`; per-instance `/var/lib/tor-instances/**`
  (not owner-qualified); logs `owner /var/log/tor/**`; runtime
  `/{,var/}run/tor/**`, `/{,var/}run/tor-instances/**`, and
  `/{,var/}run/systemd/notify`; config `/etc/tor/**`.
- Network: `inet`/`inet6` `stream` and `udp` from the abstraction.
- Exec: `obfsproxy` with `PUx` (unconfined fallback if no profile matches),
  `obfs4proxy`/`snowflake-*` with `Pix`.
- Review points:
  - `PUx` is an escape hatch; prefer `Pix` plus a transport profile, or
    document why it is acceptable.
  - Instance data is not `owner`-qualified, unlike `/var/lib/tor`.
  - Logs grant `w`, not append-only `a`; directory write is absent, so
    pre-created log files are assumed.
  - Socket paths exist without `network unix` rules.
  - The abstraction's six capabilities contradict the "minimal" header.

### i2pd: `usr.bin.i2pd`

- Attachment: `/{usr/,}bin/i2pd` only. It does not cover `/usr/sbin/i2pd` or
  `/usr/local/bin/i2pd`.
- Includes: `base`, `openssl`, `nameservice`, `ssl_certs`; local
  `local/usr.bin.i2pd`.
- Capabilities: none.
- Data/config: `/etc/i2pd/**`, `@{system_share_dirs}/i2pd/**`,
  `/var/lib/i2pd/** rwk`, `/var/log/i2pd/i2pd.log w`,
  `/{,var/}run/i2pd/** rwk`, `owner @{HOME}/.i2pd/**`.
- Network: `inet`/`inet6` `stream` and `udp`.
- Exec: self `Px`.
- Review points:
  - Attaching only `bin` is a confinement gap if the distro installs or
    symlinks the daemon under `sbin`; verify the unit.
  - No `net_bind_service`, so binding a privileged port as a non-root service
    is not covered.
  - The log file has `w` but `/var/log/i2pd/` has no `w`; first-start log
    creation is denied unless the file is pre-created.
  - `@{system_share_dirs}` requires the host tunables that define it.

### monerod: `usr.bin.monerod`

- Attachment: `/{usr/,}bin/monerod`.
- Includes: `base`, `nameservice`, `ssl_certs`; local
  `local/usr.bin.monerod`.
- Capabilities: `setgid`, `setuid`, `net_bind_service`.
- Data: `/var/lib/monero/** rwk`, `owner @{HOME}/.bitmonero/**`; logs
  `/var/log/monero/** rw`; runtime `/{,var/}run/monerod.pid` and
  `/{,var/}run/monero/**`; config `/etc/monerod.conf`.
- Network: `inet`/`inet6` `stream` plus `tcp`; no Unix sockets.
- Exec: self `Px`.
- Review points:
  - `/sys/devices/** r` is broad hardware read; narrow to the CPU data that is
    actually used if possible.
  - The log directory is read-only, so a missing log file cannot be created.
  - `tcp` rules duplicate/override the narrower `stream` grant.
  - Only `/etc/monerod.conf` is covered; distributions that use
    `/etc/monero/monerod.conf` will be denied.
  - The profile permits the home blockchain directory in addition to
    `/var/lib/monero`.

### monero-lws-daemon: `usr.bin.monero-lws-daemon`

- Attachment: `/{usr/,}bin/monero-lws-daemon`.
- Includes: `base`, `nameservice`, `ssl_certs`; local
  `local/usr.bin.monero-lws-daemon`.
- Capabilities: none.
- Data/config: `/etc/monero-lws/**` only; `owner /var/lib/monero-lws/**`;
  `owner /var/log/monero-lws/**`; `/{,var/}run/monero-lws/**`.
- Network: `inet`/`inet6` `stream` plus `tcp`.
- Exec: self `Px`.
- Review points:
  - `/etc/monero-lws.conf` (file, not directory) is not covered.
  - `owner` on logs breaks when logrotate/systemd creates root-owned files.
  - No home/user-mode rule; the daemon is assumed to run as a service user.
  - `tcp` is redundant with `stream`.

### Radicale: `usr.bin.radicale`

- Attachment: `/{usr/,}bin/radicale` (a Python script).
- Includes: `base`, `nameservice`, `python`, `ssl_certs`, `user-tmp`; local
  `local/usr.bin.radicale`.
- Capabilities: `chown`, `dac_override`, `setgid`, `setuid`.
- TLS: `/etc/letsencrypt/live/**`, `/etc/ssl/certs/**`,
  `/etc/ssl/openssl.cnf`, **`/etc/ssl/private/**`**.
- Data/config: `/etc/radicale/**`; `/var/lib/radicale/collections/**`;
  `/var/cache/radicale/**`; `/var/log/radicale/**`;
  `/{,var/}run/radicale.sock` and `/run/radicale/**`.
- Exec: `/{usr/,}bin/python3 pix`, self `mrpx`; denies for one aarch64 GCC 14
  toolchain and `ldconfig`.
- Review points:
  - Reading all of `/etc/ssl/private/**` exposes every service's private key;
    restrict to Radicale's own certificate/key paths.
  - `dac_override` plus `/proc/** r` is broader than a normal service needs.
  - `/dev/null rwk` includes an unnecessary `k`.
  - The comment claims `pix` avoids environment scrubbing; lowercase `pix`
    scrubs. Either the comment or the mode is wrong.
  - The deny list is architecture/version-specific and is not a meaningful
    boundary beyond AppArmor's default deny.
  - `/{usr/,}bin/python3` may not match a versioned interpreter path.

### OpenDKIM: `usr.sbin.opendkim`

- Attachment: `/{usr/,}sbin/opendkim`.
- Includes: `base`, `nameservice`, `ssl_certs`; local
  `local/usr.sbin.opendkim`.
- Capabilities: `setgid`, `setuid`, `chown`, `dac_override`,
  `dac_read_search`; `deny ptrace (readby,trace)`.
- Sockets: `/{,var/}run/opendkim/opendkim.sock`, the Postfix spool sockets,
  `/{,var/}run/opendkim/opendkim.pid`.
- Keys: `/etc/dkimkeys/**`, `/etc/postfix/dkim/**`; config
  `/etc/opendkim.conf` and `/etc/default/opendkim`.
- Logs: `/var/log/mail.*`, `/var/log/opendkim/**`, `/var/log/mail/**`.
- Network: `inet`/`inet6` `stream` and `dgram`.
- Review points:
  - `/etc/opendkim/**` (the common key layout) is not covered.
  - Writing to the whole `/var/log/mail/**` tree is broader than necessary.
  - Socket paths lack `network unix` rules; the milter interface may be denied
    on releases that mediate AF_UNIX.
  - `/{usr/,}lib/** mr` is a broad library grant.
  - Keytable/signingtable/trustedhosts rules are subsumed by the directory
    rule.

### Fail2Ban: `usr.bin.fail2ban-server`

- Attachment: `/{usr/,usr/local/}bin/fail2ban-server`.
- Includes: `base`, `nameservice`, `python`, `ssl_certs`; local
  `local/usr.bin.fail2ban-server`.
- Capabilities: `net_admin`.
- Network: `unix stream`, `netlink raw`, plus `inet`/`inet6` from
  `nameservice`.
- Config/data: `/etc/fail2ban/**`, `/etc/default/fail2ban`,
  `/etc/sysconfig/fail2ban`, `/usr/share/fail2ban/**`,
  `/usr/local/share/fail2ban/**`; `/var/lib/fail2ban/**`,
  `/var/cache/fail2ban/**`, `/{,var/}run/fail2ban/**`, `/var/log/fail2ban*`.
- Logs read: auth, secure, messages, syslog, apache2, httpd, nginx, postfix;
  journal files; `/etc/machine-id`, boot ID; `/run/xtables.lock`.
- Helpers: shells and text utilities, `ip`, `iptables`, `ip6tables`, `nft`,
  `xtables-nft-multi` with `ix`.
- Review points:
  - `network netlink raw` grants all netlink families; pair it with
    `net_admin` carefully.
  - Shells and firewall helpers inherit the root/net_admin profile via `ix`;
    there is no child-profile boundary.
  - The journal **socket** and `network unix dgram` are missing, so
    `backend = systemd` may fail even though journal files are readable.
  - Common action helpers (`ipset`, `iptables-legacy`, `xtables-legacy-multi`,
    `cut`, `wc`, `xargs`, `logger`, `curl`, `whois`, `sendmail`) are absent.
  - `fail2ban-client`/`fail2ban-regex` are granted `mr` but are not executed by
    the server.
  - `/var/run/xtables.lock` duplicates `/run/xtables.lock`.

### xd-torrent: `usr.bin.xd-torrent`

- Attachment: `/{usr/,usr/local/}bin/{XD,xd-torrent}`; profile name is
  `xd-torrent`.
- Includes: `base`, `nameservice`, `ssl_certs`; local
  `local/usr.bin.xd-torrent`.
- Capabilities: none.
- Config/state: `/etc/{xd,XD}.conf`, `/etc/{xd,XD}/**`,
  `/usr/local/etc/{xd,XD}...`, `/var/lib/{xd,XD}/**`,
  `/var/log/{xd,XD}/**`, `/{,var/}run/{xd,XD}/**`.
- User mode: `owner @{HOME}/.config/{xd,XD,xd-torrent}/**`,
  `.local/share/...`, `.cache/...`.
- Network: `inet`/`inet6` `stream`, `tcp`, `udp`.
- Exec: self `Px`.
- Review points:
  - There is no writable download directory. User-mode downloads outside the
    three dot-directories are denied, despite the "user-mode" comment.
  - The uppercase `XD` paths may be dead; verify before keeping them.
  - No Unix socket rule despite the commented I2P SAM/RPC use.
  - `tcp`/`udp` duplicate the `stream` grant.

## Procedure

1. Identify the daemon and read its profile plus any abstraction it includes.
2. Build a table of expected behavior from the unit/package: executable path,
   user, config, data, logs, sockets, ports, helper programs.
3. Walk each profile rule and mark it: required, too broad, missing, or dead.
4. For each missing/denied item, write the narrowest candidate rule and the
   evidence for it. Do not add a directory-wide `rw` to silence a single file.
5. Check cross-cutting issues: profile name vs file name, attachment glob,
   `owner` semantics, directory-create permissions, AF_UNIX mediation,
   capability justification, exec transitions, and duplicate rules.
6. Validate with `apparmor-policy-validation`; only run runtime tests with
   explicit authorization.

For documentation-only reviews, comments may state the direct scope and
security consequence of checked-in rules, but must distinguish that evidence
from assumptions about deployment intent. Preserve all active policy tokens
and report broad permissions as findings rather than silently correcting
them.

## Validation

- Static: every path in the review table appears in the profile with the right
  permission; every included abstraction exists.
- Syntax: `make check` or a per-profile parser check, if authorized.
- Runtime: complain mode plus the daemon's real workload, then
  `journalctl -g apparmor`; confirm zero unexplained denials before enforcing.
- A review is not complete if it only says "no syntax errors". It must state
  whether behavior was actually exercised.

## References

- `AGENTS.md` for safety and conventions.
- `apparmor-profile-authoring` for rule-level guidance.
- `apparmor-policy-validation` for denial triage.
- Upstream documentation and the installed unit files for deployment facts.

## Maintenance & Continuous Learning

After using this skill to modify any repository content, review this skill and
its related `AGENTS.md` and skills once the implementation is complete. Update
this skill when the task establishes reusable knowledge or changes a procedure,
tool, configuration, path, assumption, example, or validation step. Correct any
instruction that proved inaccurate, remove obsolete or contradictory guidance,
and keep cross-references working. Do not record one-off execution details.

Every repository change must include a substantive, relevant agent/skills
update. Run `perl scripts/check-agent-sync.pl --base <base-ref>` and review the diff for semantic relevance; the validator checks
structure and detectable references but cannot establish relevance. Report the
skills and agent instructions reviewed, updates made, checks actually run, and
PASS/FAIL synchronization status. A failed or skipped synchronization means
the task is incomplete.
