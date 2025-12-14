#!/usr/bin/perl

# Sync selected upstream AppArmor profiles (apache2, postfix, dovecot, spamc/spamd,
# clamav/clamd) into this tree and force enforce mode, along with required
# abstractions/tunables. Useful for keeping local installs up to date without
# trusting distribution lag. APPARMOR_REMOTE and APPARMOR_TARGET env vars let you
# point at an alternate repo or staging directory.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

use strict;
use warnings;

use Cwd qw(abs_path);
use File::Basename qw(basename dirname);
use File::Find;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;

my $GREEN = "\e[32m";
my $YELLOW = "\e[33m";
my $RED = "\e[31m";
my $CYAN = "\e[36m";
my $BOLD = "\e[1m";
my $RESET = "\e[0m";

sub log {
    my ($msg) = @_;
    print "${GREEN}✅ [INFO]${RESET} $msg\n";
}

sub warn {
    my ($msg) = @_;
    print STDERR "${YELLOW}⚠️  [WARN]${RESET} $msg\n";
}

sub error {
    my ($msg, $code) = @_;
    $code //= 1;
    print STDERR "${RED}❌ [ERROR]${RESET} $msg\n";
    exit $code;
}

# Backward-compatible aliases
sub info     { log(@_); }
sub warn_msg { warn(@_); }

# Copy upstream profiles for apache2, postfix, dovecot, spamc/spamd, and clamav/clamd
# from the AppArmor repository into this tree and ensure they use enforce mode.

my $remote_repo = $ENV{APPARMOR_REMOTE} // 'https://gitlab.com/apparmor/apparmor.git';
my @source_roots = (
    'profiles/apparmor/profiles/extras',
    'profiles/apparmor.d',
);
my @keywords = qw(apache2 postfix dovecot spamc spamd clamd freshclam clamav);
my @abstractions = (
    qr{<abstractions/apache2-common>},
    qr{<abstractions/postfix-common>},
    qr{<abstractions/dovecot-common>},
);
my %deps;

my $target_root = abs_path($ENV{APPARMOR_TARGET} // '/etc/apparmor.d');

run();

sub run {
    my $checkout = tempdir(CLEANUP => 1);
    system('git', 'clone', '--depth', '1', $remote_repo, $checkout) == 0
        or error("Failed to clone $remote_repo");

    my @selected;
    for my $root_rel (@source_roots) {
        my $root = File::Spec->catdir($checkout, split m{/+}, $root_rel);
        next unless -d $root;

        File::Find::find({
            wanted => sub {
                return if -d $_;
                my $relative = File::Spec->abs2rel($File::Find::name, $root);
                my $lower = lc $relative;
                my $path = $File::Find::name;
                my $matches_keyword = grep { index($lower, $_) >= 0 } @keywords;
                my $matches_abstraction = file_matches_abstraction($path);
                return unless $matches_keyword || $matches_abstraction;
                return if $exclude{basename($relative)};
                push @selected, [$root, $relative];
            },
            no_chdir => 1,
        }, $root);
    }

    error('No matching profiles found') unless @selected;

    for my $entry (@selected) {
        my ($root, $relative) = @$entry;
        my $source = File::Spec->catfile($root, $relative);
        my $dest = File::Spec->catfile($target_root, $relative);

        my $raw = slurp($source);
        collect_deps($raw);
        my $data = ensure_enforce($raw);

        make_path(dirname($dest)) unless -d dirname($dest);
        write_file($dest, $data);
        log("Updated $relative");
    }

    copy_deps($checkout);
}

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or error("Cannot read $path: $!");
    local $/;
    my $data = <$fh>;
    close $fh;
    return $data;
}

sub write_file {
    my ($path, $data) = @_;
    open my $fh, '>', $path or error("Cannot write $path: $!");
    print {$fh} $data;
    close $fh;
    chmod 0644, $path;
}

sub ensure_enforce {
    my ($text) = @_;

    $text =~ s{(^\s*profile\s+[^\n\{]+?)           # profile header
               (?:\s+flags=\(\s*([^)]+?)\s*\))?   # optional flags
               (\s*\{)                               # opening brace
              }{
        my ($prefix, $flag_body, $brace) = ($1, $2 // '', $3);
        my @flags = grep { length } map { s/^\s+|\s+$//gr } split /[,\s]+/, $flag_body;
        my %seen;
        @flags = grep { !$seen{$_}++ } @flags;
        push @flags, 'enforce' unless grep { $_ eq 'enforce' } @flags;
        my $flag_text = ' flags=(' . join(',', @flags) . ')';
        "$prefix$flag_text$brace";
    }xmge;

    return $text;
}

sub file_matches_abstraction {
    my ($path) = @_;
    open my $fh, '<', $path or return 0;
    while (my $line = <$fh>) {
        return 1 if grep { $line =~ $_ } @abstractions;
    }
    return 0;
}

sub collect_deps {
    my ($text) = @_;
    while ($text =~ /include\s+(?:if\s+exists\s+)?<([^>]+)>/g) {
        my $path = $1;
        $deps{$path} = 1 if $path =~ m{^(abstractions|tunables)/};
    }
    while ($text =~ /abi\s+<([^>]+)>/g) {
        my $path = $1;
        $deps{$path} = 1 if $path =~ m{^abi/};
    }
}

sub copy_deps {
    my ($checkout) = @_;
    for my $rel (sort keys %deps) {
        my $source = File::Spec->catfile($checkout, 'profiles', 'apparmor.d', split m{/+}, $rel);
        next unless -f $source;
        my $dest = File::Spec->catfile($target_root, split m{/+}, $rel);
        make_path(dirname($dest)) unless -d dirname($dest);
        my $data = slurp($source);
        write_file($dest, $data);
        log("Updated $rel");
    }
}
