#!/usr/bin/perl

# AppArmor profile synchronization script
# Fetches selected upstream AppArmor profiles from the official
# AppArmor Git repository and updates local profiles accordingly.
# Ensures that the profiles are set to enforce mode and
# that the exec_path tunable is properly defined.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

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

GetOptions(
    'abstractions-only|a' => \$abstractions_only,
    'keywords|k=s'        => \$keyword_list,
) or die_tool("Invalid options\n");

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
        my $data = ensure_enforce($raw);
        $data = ensure_exec_var($data);

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
    my ($text) = @_;

    my @lines = split /\n/, $text, -1;    # keep trailing newline if present

    for my $line (@lines) {
        next unless $line =~ /^\s*profile\b/;
        my $brace_pos = rindex( $line, '{' );
        next if $brace_pos < 0;           # malformed line; leave untouched

        my $header = substr( $line, 0, $brace_pos );
        my $after =
          substr( $line, $brace_pos );    # includes '{' and following spaces
        $after =~ s/^\s*\{/{/;            # normalize spacing before the brace

        my $flag_body = '';
        if ( $header =~ s/\s+flags=\(\s*([^)]+?)\s*\)// ) {
            $flag_body = $1;
        }

        my @flags = grep { length } map { s/^\s+|\s+$//gr } split /[,\s]+/,
          $flag_body;
        my %seen;
        @flags = grep { !$seen{$_}++ } @flags;
        push @flags, 'enforce' unless $seen{'enforce'};

        my $flag_text = ' flags=(' . join( ',', @flags ) . ')';
        $header =~ s/\s+$//;    # trim trailing space before re-adding flags

        $line = $header . $flag_text . ' ' . $after;
    }

    return join( "\n", @lines );
}

sub ensure_exec_var {
    my ($text) = @_;

    return $text unless $text =~ /\@\{exec_path\}/;

    $text =~ s/^\s*\@\{exec_path\}\s*=.*\n//mg;

    if ( $text !~ /include\s+<tunables\/exec>/ ) {
        my @lines     = split /\n/, $text, -1;
        my $insert_at = 0;
        for my $i ( 0 .. $#lines ) {
            if ( $lines[$i] =~ /include\s+<tunables\/global>/ ) {
                $insert_at = $i + 1;
                last;
            }
            last if $lines[$i] =~ /^\s*profile\b/;
            $insert_at = $i + 1
              if $lines[$i] =~ /^\s*#/ || $lines[$i] =~ /^\s*$/;
        }
        splice @lines, $insert_at, 0, 'include <tunables/exec>';
        $text = join( "\n", @lines );
    }

    return $text;
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
    my $dest = File::Spec->catfile( $target_root, 'tunables', 'exec' );

    my $needs_write = 1;
    if ( -f $dest ) {
        my $existing = slurp($dest);
        $needs_write = ( $existing !~ /\@\{exec_path\}/ );
    }

    return unless $needs_write;

    make_path( dirname($dest) ) unless -d dirname($dest);
    my $content = <<'EOF';
# AppArmor tunable: exec_path for postfix multi-call binaries
# Adjust locally if your distribution uses different paths.

@{exec_path}=/usr/lib{,exec}/postfix/{,bin/,sbin/}
EOF

    write_file( $dest, $content );
    logi('Ensured tunables/exec with @{exec_path}');
}
