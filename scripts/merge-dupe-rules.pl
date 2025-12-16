#!/usr/bin/perl
use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use File::Find;
use File::Copy qw(copy);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use POSIX qw(strftime);

# -------------------------
# Logging
# -------------------------
my $no_color  = 0;
my $is_tty    = ( -t STDOUT )             ? 1 : 0;
my $use_color = ( !$no_color && $is_tty ) ? 1 : 0;

my ( $GREEN, $YELLOW, $RED, $RESET ) = ( "", "", "", "" );
if ($use_color) {
    $GREEN  = "\e[32m";
    $YELLOW = "\e[33m";
    $RED    = "\e[31m";
    $RESET  = "\e[0m";
}

sub logi { print "${GREEN}✅ [INFO]${RESET} $_[0]\n"; }
sub logw { print STDERR "${YELLOW}⚠️  [WARN]${RESET} $_[0]\n"; }
sub loge { print STDERR "${RED}❌ [ERROR]${RESET} $_[0]\n"; }

sub die_tool {
    my ($msg) = @_;
    loge($msg);
    exit 1;
}

# -------------------------
# Options
# -------------------------
my $policy_dir     = "/etc/apparmor.d";
my $apply          = 0;   # default: dry-run
my $backup_suffix  = "";
my $verbose        = 0;

sub usage {
  print STDERR <<"USAGE";
Usage:
  $0 [--policy-dir DIR] [--apply] [--backup-suffix SUFFIX] [--verbose]

What it does:
  - Scans AppArmor policy files under DIR.
  - Merges consecutive duplicate file rules (same qualifiers + same path) by unioning permissions.

Safe/Conservative:
  - Only merges simple single-line file path rules ending with ',' where the path starts with '/' or '@{...}'.
  - Does not touch dbus/capability/network/mount/etc rules, includes, or rename/link rules (lines containing '->').

Default mode:
  - Dry-run (prints plan). Use --apply to write changes.

Exit codes:
  0 OK / no changes
  2 Changes would be made (dry-run) or some files could not be processed
USAGE
  exit 2;
}

GetOptions(
  "policy-dir=s"    => \$policy_dir,
  "apply!"          => \$apply,
  "backup-suffix=s" => \$backup_suffix,
  "verbose!"        => \$verbose,
) or usage();

 -d $policy_dir or do { loge("ERROR: not a directory: $policy_dir"); exit 2; };

if (!$backup_suffix) {
  my $ts = strftime("%Y%m%d-%H%M%S", localtime());
  $backup_suffix = ".bak.$ts";
}

# -------------------------
# Helpers
# -------------------------
sub split_comment {
  my ($line) = @_;
  my $in_quote = 0;
  for (my $i = 0; $i < length($line); $i++) {
    my $ch = substr($line, $i, 1);
    $in_quote = !$in_quote if $ch eq '"';
    if ($ch eq '#' && !$in_quote) {
      return (substr($line, 0, $i), substr($line, $i));
    }
  }
  return ($line, "");
}

sub normalize_ws {
  my ($s) = @_;
  $s =~ s/\s+/ /g;
  $s =~ s/^\s+|\s+$//g;
  return $s;
}

sub perm_atoms {
  my ($perm_str) = @_;
  $perm_str //= "";
  $perm_str =~ s/,/ /g;
  $perm_str = normalize_ws($perm_str);

  my @atoms;
  my %seen;

  for my $tok (grep { length } split(/\s+/, $perm_str)) {
    # If token ends with 'x' and is longer than 1, treat as an exec-mode token (ix/px/cx/Ux/Pix/etc.)
    if (length($tok) > 1 && $tok =~ /x$/i) {
      push @atoms, $tok unless $seen{$tok}++;
      next;
    }
    # Otherwise split into single letters (rwkmll etc.)
    for my $ch (split(//, $tok)) {
      next if $ch =~ /\s/;
      push @atoms, $ch unless $seen{$ch}++;
    }
  }
  return @atoms;
}

sub join_atoms {
  my (@atoms) = @_;
  return join("", @atoms);
}

sub is_skippable_file {
  my ($path) = @_;
  return 1 if $path =~ m{/(?:cache|\.cache)/};
  return 1 if $path =~ /\.(?:swp|bak|dpkg-old|dpkg-dist|rpmnew|rpmsave)$/;
  return 1 if $path =~ /~$/;
  return 0;
}

# Parse a *simple* AppArmor file rule:
#   [indent][qualifiers] <path> <perms>,
# where qualifiers can include audit/deny/owner (in any order),
# and <path> must start with '/' or '@{...}' (unquoted or quoted).
sub parse_file_rule {
  my ($raw) = @_;

  return undef if $raw =~ /->/;               # avoid rename/link rules
  return undef if $raw !~ /,\s*$/;            # must end with a comma (after stripping comment)
  return undef if $raw =~ /^\s*(?:include|#include)\b/i;

  # reject obvious non-path rule starters
  return undef if $raw =~ /^\s*(?:dbus|capability|network|mount|signal|ptrace|unix|change_profile|profile)\b/i;

  my ($indent) = ($raw =~ /^(\s*)/);
  my $body = $raw;
  $body =~ s/^\s+//;

  # qualifiers
  my $qual = "";
  while ($body =~ s/^(audit|deny|owner)\s+//i) {
    $qual .= lc($1) . " ";
  }
  $qual = normalize_ws($qual);

  # path token: quoted or unquoted
  my $path = "";
  if ($body =~ s/^"([^"]+)"\s+//) {
    $path = qq{"$1"};
  } elsif ($body =~ s/^(\S+)\s+//) {
    $path = $1;
  } else {
    return undef;
  }

  # only merge if path begins with '/' or '@{'
  my $path_check = $path;
  $path_check =~ s/^"//; # if quoted
  return undef unless ($path_check =~ m{^/} || $path_check =~ m{^\@\{});

  # perms until trailing comma
  $body =~ s/,\s*$//;
  my $perms = normalize_ws($body);
  return undef if $perms eq "";

  my $key = join("|", $indent, $qual, $path); # conservative: includes indent + qualifiers + path

  return {
    indent => $indent,
    qual   => $qual,
    path   => $path,
    perms  => $perms,
    key    => $key,
  };
}

sub make_rule_line {
  my (%args) = @_;
  my $indent  = $args{indent} // "";
  my $qual    = $args{qual}   // "";
  my $path    = $args{path}   // "";
  my $perms   = $args{perms}  // "";
  my $comment = $args{comment} // "";

  my $lhs = $qual ? ($qual . " " . $path) : $path;
  $lhs = normalize_ws($lhs);

  my $line = $indent . $lhs . " " . $perms . ",";
  $line .= " " . $comment if defined($comment) && $comment ne "";
  return $line;
}

# -------------------------
# Transform one file
# -------------------------
sub transform_lines {
  my (@lines) = @_;

  my @out;

  my $pending;          # hashref from parse_file_rule + merged atoms, comment, newline
  my @pending_atoms;
  my %pending_seen;
  my $pending_comment = "";
  my $pending_nl = "\n";
  my @gap = ();         # blank/comment-only lines between duplicates

  my $flush = sub {
    return unless $pending;

    my $perms = join_atoms(@pending_atoms);
    my $merged = make_rule_line(
      indent  => $pending->{indent},
      qual    => $pending->{qual},
      path    => $pending->{path},
      perms   => $perms,
      comment => $pending_comment,
    );
    push @out, $merged . $pending_nl;
    push @out, @gap if @gap;

    $pending = undef;
    @pending_atoms = ();
    %pending_seen = ();
    $pending_comment = "";
    $pending_nl = "\n";
    @gap = ();
  };

  for my $line (@lines) {
    my $has_nl = ($line =~ /\n\z/) ? 1 : 0;
    my $nl = $has_nl ? "\n" : "";

    my $raw = $line;
    $raw =~ s/\n\z// if $has_nl;

    my ($body, $comment) = split_comment($raw);
    my $trimmed = $body;
    $trimmed =~ s/\s+$//;

    # blank or comment-only line
    if ($trimmed =~ /^\s*$/) {
      if ($pending) {
        push @gap, $line; # keep as-is
      } else {
        push @out, $line;
      }
      next;
    }

    my $rule = parse_file_rule($trimmed);
    if ($rule) {
      if ($pending && $rule->{key} eq $pending->{key}) {
        # merge permissions
        for my $a (perm_atoms($rule->{perms})) {
          next if $pending_seen{$a}++;
          push @pending_atoms, $a;
        }

        # keep first comment, but if first is empty and this has one, adopt it
        if (!$pending_comment && $comment) {
          $pending_comment = $comment;
        }

        # keep newline style from first line in the run
        next;
      }

      # new rule starts -> flush previous run
      $flush->() if $pending;

      $pending = $rule;
      @pending_atoms = ();
      %pending_seen = ();
      for my $a (perm_atoms($rule->{perms})) {
        next if $pending_seen{$a}++;
        push @pending_atoms, $a;
      }
      $pending_comment = $comment // "";
      $pending_nl = $nl;
      @gap = ();
      next;
    }

    # non-mergeable line: flush pending then pass through
    $flush->() if $pending;
    push @out, $line;
  }

  $flush->() if $pending;
  return @out;
}

# -------------------------
# Walk files
# -------------------------
my @files;
find(
  {
    no_chdir => 1,
    wanted   => sub {
      return if -d $File::Find::name;
      return if is_skippable_file($File::Find::name);
      push @files, $File::Find::name;
    },
  },
  $policy_dir
);

@files = sort @files;

my @planned;
my $errors = 0;

for my $f (@files) {
  # Read as text-ish, but don't die on odd bytes
  open my $fh, "<", $f or next;
  my @orig = <$fh>;
  close $fh;

  my @new = transform_lines(@orig);

  if (@new != @orig || join("", @new) ne join("", @orig)) {
    push @planned, [$f, join("", @orig), join("", @new)];
  }
}

if (!@planned) {
  logi("No changes planned.");
  exit 0;
}

for my $i (0 .. $#planned) {
  last if $i >= 30;
  logi("PLAN: $planned[$i]->[0]");
}
logi("... and " . (@planned - 30) . " more files") if @planned > 30;

if (!$apply) {
  logw("Dry-run only. Re-run with --apply to write changes.");
  exit 2;
}

for my $p (@planned) {
  my ($file, $old, $new) = @$p;

  my $backup = "/var/backups" . $file . $backup_suffix;
  my $bdir = dirname($backup);
  unless (-d $bdir) {
    make_path($bdir) or do { loge("ERROR: failed to create backup dir: $bdir: $!"); $errors++; next; };
  }

  if (!copy($file, $backup)) {
    loge("ERROR: failed to create backup: $file -> $backup: $!");
    $errors++;
    next;
  }

  open my $out, ">", $file or do {
    loge("ERROR: failed to write $file: $!");
    $errors++;
    next;
  };
  print {$out} $new;
  close $out;

  logi("WROTE: $file (backup: $backup)") if $verbose;
}

print "\nDone.\n";
exit($errors ? 2 : 0);
