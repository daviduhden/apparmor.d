#!/usr/bin/perl

# AppArmor profile synchronization script
# Fetches selected upstream AppArmor profiles from the official
# AppArmor Git repository and updates local profiles accordingly.
# Ensures that the profiles are set to enforce mode and
# that the exec_path tunable is properly defined.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.
#
# Usage:
#   perl sync-profiles.pl [--abstractions-only] [--keywords=kw1,kw2,...] [--mode=enforce|complain]
# Options:
#   --abstractions-only : Only sync abstraction and abi files.
#   --keywords         : Comma-separated list of keywords to filter profiles.
#   --mode             : Set profiles to 'enforce' or 'complain' mode (default: enforce).

use strict;
use warnings;

use Cwd            qw(abs_path);
use File::Basename qw(basename dirname);
use File::Find;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Getopt::Long qw(GetOptions);

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

# Copy upstream profiles for apache2, postfix, dovecot, spamc/spamd, and clamav/clamd
# from the AppArmor repository into this tree and ensure they use enforce mode.

my $remote_repo = $ENV{APPARMOR_REMOTE}
  // 'https://gitlab.com/apparmor/apparmor.git';
my @source_roots =
  ( 'profiles/apparmor/profiles/extras', 'profiles/apparmor.d', );
my @keywords = qw(ssh sshd apache2 postfix dovecot spamc spamd clamd freshclam clamav);
my @abstractions = (
    qr{<abstractions/apache2-common>},
    qr{<abstractions/postfix-common>},
    qr{<abstractions/dovecot-common>},
);
my %deps;
my %exclude;

my $target_root = abs_path( $ENV{APPARMOR_TARGET} // '/etc/apparmor.d' );

# CLI options
my $abstractions_only = 0;
my $keyword_list      = '';

my $opt_mode;
GetOptions(
    'abstractions-only|a' => \$abstractions_only,
    'keywords|k=s'        => \$keyword_list,
    'mode|m=s'            => \$opt_mode,
) or die_tool("Invalid options\n");

my $mode = defined $opt_mode ? lc $opt_mode : 'enforce';
if ($mode ne 'enforce' && $mode ne 'complain') {
    die_tool("Invalid mode: $mode (must be 'enforce' or 'complain')\n");
}

if ( $keyword_list ) {
    my @k = split /,\s*/, $keyword_list;
    @k = map { lc $_ } grep { length } @k;
    if (@k) {
        @keywords = @k;
        logi("Using keywords: " . join(', ', @keywords));
    }
}

if ($abstractions_only) {
    logi("Running in abstractions-only mode: only sync abstractions and abi files");
}

run();

sub run {
    my $checkout = tempdir( CLEANUP => 1 );
    system( 'git', 'clone', '--depth', '1', $remote_repo, $checkout ) == 0
      or loge("Failed to clone $remote_repo");

    my @selected;
    for my $root_rel (@source_roots) {
        my $root = File::Spec->catdir( $checkout, split m{/+}, $root_rel );
        next unless -d $root;

        File::Find::find(
            {
                wanted => sub {
                    return if -d $_;
                    my $relative =
                      File::Spec->abs2rel( $File::Find::name, $root );
                    my $lower = lc $relative;
                    my $path  = $File::Find::name;
                    # If abstractions-only mode, include only files under
                    # 'abstractions' or 'abi' directories (relative to the
                    # scanned root). This allows syncing only abstractions
                    # and abi files.
                    if ($abstractions_only) {
                        if ( $relative =~ m{(?:^|/)abstractions/} || $relative =~ m{(?:^|/)abi/} ) {
                            push @selected, [ $root, $relative ];
                        }
                        return;
                    }

                    my $matches_keyword = grep { index( $lower, $_ ) >= 0 } @keywords;
                    my $matches_abstraction = file_matches_abstraction($path);
                    return unless $matches_keyword || $matches_abstraction;
                    return if $exclude{ basename($relative) };
                    push @selected, [ $root, $relative ];
                },
                no_chdir => 1,
            },
            $root
        );
    }

    loge('No matching profiles found') unless @selected;

    for my $entry (@selected) {
        my ( $root, $relative ) = @$entry;
        my $source = File::Spec->catfile( $root,        $relative );
        my $dest   = File::Spec->catfile( $target_root, $relative );

            my $raw = slurp($source);
            collect_deps($raw);
            my $data = ensure_enforce($raw, $relative);
            $data = ensure_exec_var($data, $relative);

        make_path( dirname($dest) ) unless -d dirname($dest);
        write_file( $dest, $data );
        logi("Updated $relative");
    }

    copy_deps($checkout);
    ensure_exec_tunable();
}

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or loge("Cannot read $path: $!");
    local $/;
    my $data = <$fh>;
    close $fh;
    return $data;
}

sub write_file {
    my ( $path, $data ) = @_;
    open my $fh, '>', $path or loge("Cannot write $path: $!");
    print {$fh} $data;
    close $fh;
    chmod 0644, $path;
}

sub ensure_enforce {
    my ($text, $relative) = @_;

    my $wanted = $mode eq 'complain' ? 'complain' : 'enforce';

    my @lines = split /\n/, $text, -1;    # keep trailing newline if present

    for my $i (0..$#lines) {
        my $line = $lines[$i];
        next unless $line =~ /^\s*profile\b/;
        my $brace_pos = rindex( $line, '{' );
        next if $brace_pos < 0;           # malformed line; leave untouched

        my $header = substr( $line, 0, $brace_pos );
        my $after = substr( $line, $brace_pos );    # includes '{' and following spaces
        $after =~ s/^\s*\{/{/;            # normalize spacing before the brace

        my $flag_body = '';
        if ( $header =~ s/\s+flags=\(\s*([^)]+?)\s*\)// ) {
            $flag_body = $1;
        }

        # extract the part after 'profile'
        my $rest = $header;
        $rest =~ s/^\s*profile\s*//;
        $rest =~ s/\s+$//;

        my $profile_name = '';
        my $path_part = '';

        if ( $rest =~ m{^(/|$)} ) {
            # starts with path => no explicit name
            $path_part = $rest;
        } else {
            # assume first token is name
            if ( $rest =~ s/^([\w_.+-]+)\s*// ) {
                $profile_name = $1;
                $path_part = $rest;
            } else {
                $path_part = $rest;
            }
        }

        # if no profile_name, derive from $relative
        if (!$profile_name) {
            if (defined $relative && $relative =~ m{([^/]+)$}) {
                $profile_name = $1;
                $profile_name =~ s/\./_/g;
            }
        }

        # normalize flags, ensure wanted present and remove opposite
        my @flags = grep { length } map { s/^\s+|\s+$//gr } split /[,\s]+/, $flag_body;
        my %seen;
        @flags = grep { !$seen{$_}++ } @flags;
        # remove the other mode if present
        if ($wanted eq 'enforce') {
            @flags = grep { $_ ne 'complain' } @flags;
        } else {
            @flags = grep { $_ ne 'enforce' } @flags;
        }
        push @flags, $wanted unless $seen{$wanted};

        my $flag_text = @flags ? ' flags=(' . join( ',', @flags ) . ')' : '';

        $profile_name =~ s/\s+/_/g if defined $profile_name;

        my $new_header = 'profile';
        $new_header .= ' ' . $profile_name if $profile_name;
        $new_header .= ' ' . $path_part if defined $path_part && $path_part ne '';
        $new_header =~ s/\s+$//;

        $lines[$i] = $new_header . $flag_text . ' ' . $after;
    }

    return join( "\n", @lines );
}

sub ensure_exec_var {
    my ($text, $relative) = @_;

    # Only act on profiles that *use* @{exec_path} somewhere.
    return $text unless $text =~ /\@\{exec_path\}/;

    # If the profile already *defines* @{exec_path}=, leave it alone.
    return $text if $text =~ /^\s*\@\{exec_path\}\s*=.*$/m;

    # Remove any stray definition lines just in case
    $text =~ s/^\s*\@\{exec_path\}\s*=.*\n//mg;

    my @lines = split /\n/, $text, -1;

    my $binpath = '';
    if (defined $relative && length $relative) {
        my ($name) = $relative =~ m{([^/]+)$};
        $name //= '';

        # Find the first usage of the variable and search for paths that
        # occur before the `{` that precedes that usage. Prefer the first
        # absolute path found before that brace.
        my $pos_use = index($text, '@{exec_path}');
        if ($pos_use >= 0) {
            my $before = substr($text, 0, $pos_use);
            my $pos_brace = rindex($before, '{');
            my $search_end = $pos_brace >= 0 ? $pos_brace : $pos_use;
            $before = substr($text, 0, $search_end);

            my @prefix_candidates = ();
            while ( $before =~ m{(/(?:usr/local/bin|usr/bin|usr/sbin|/usr/sbin|/bin|/sbin|/usr/libexec|/libexec)/[A-Za-z0-9._+\-]+)}g ) {
                push @prefix_candidates, $1;
            }
            if (@prefix_candidates) {
                $binpath = $prefix_candidates[0];
            }
        }

        # If none found before the brace, fall back to scanning the whole
        # profile content and prefer a basename match, then first candidate.
        if (!$binpath) {
            my @candidates = ();
            while ( $text =~ m{(/(?:usr/local/bin|usr/bin|usr/sbin|/usr/sbin|/bin|/sbin|/usr/libexec|/libexec)/[A-Za-z0-9._+\-]+)}g ) {
                push @candidates, $1;
            }
            if (@candidates && $name) {
                my ($base) = $name =~ m{([^\.]+)$};
                for my $c (@candidates) {
                    if ($c =~ m{/$base(?:$|\b)}) { $binpath = $c; last }
                }
            }
            $binpath ||= $candidates[0] || '';

            # final fallback: derive path from profile name (e.g. usr.bin.foo -> /usr/bin/foo)
            if (!$binpath && $name) {
                $binpath = '/' . ( $name =~ s/\./\//gr );
            }
        }
    }

    # Insert @{exec_path} definition immediately before the first `profile`
    # declaration in the file (so it's local to this profile file).
    if ($binpath) {
        my $insert_at = 0;
        for my $i (0..$#lines) {
            if ( $lines[$i] =~ /^\s*profile\b/ ) { $insert_at = $i; last }
        }
        splice @lines, $insert_at, 0, "\@{exec_path}=$binpath";
    }

    return join("\n", @lines);
}

sub file_matches_abstraction {
    my ($path) = @_;
    open my $fh, '<', $path or return 0;
    while ( my $line = <$fh> ) {
        return 1 if grep { $line =~ $_ } @abstractions;
    }
    return 0;
}

sub collect_deps {
    my ($text) = @_;
    while ( $text =~ /include\s+(?:if\s+exists\s+)?<([^>]+)>/g ) {
        my $path = $1;
        $deps{$path} = 1 if $path =~ m{^(abstractions|tunables)/};
    }
    while ( $text =~ /abi\s+<([^>]+)>/g ) {
        my $path = $1;
        $deps{$path} = 1 if $path =~ m{^abi/};
    }
}

sub copy_deps {
    my ($checkout) = @_;
    for my $rel ( sort keys %deps ) {
        my $source = File::Spec->catfile( $checkout, 'profiles', 'apparmor.d',
            split m{/+}, $rel );
        next unless -f $source;
        my $dest = File::Spec->catfile( $target_root, split m{/+}, $rel );
        make_path( dirname($dest) ) unless -d dirname($dest);
        my $data = slurp($source);
        write_file( $dest, $data );
        logi("Updated $rel");
    }
}

sub ensure_exec_tunable {
    # Per policy change, do not create a shared tunable. Each profile should
    # define its own @{exec_path} locally. Keep this function a no-op.
    return;
}
