#!/usr/bin/perl

# AppArmor enforce-complain toggle script
# Saves the list of profiles currently in enforce mode to a state file,
# then switches them to complain mode. Can later restore the profiles
# back to enforce mode using the saved state file.
# Usage:
#   enforce-complain-toggle.pl [--state-file PATH] [--dry-run] downgrade
#   enforce-complain-toggle.pl [--state-file PATH] [--dry-run] restore
# Options:
#   --state-file PATH   State file to save/read the list
#                      (default: /var/lib/apparmor/enforce_to_complain.list)
#   --dry-run           Do not change anything; only print commands
#   --help              Show this help
# Requires 'apparmor-utils' package for aa-complain and aa-enforce.
# Must be run as root (use sudo) to apply changes.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

use strict;
use warnings;
use Getopt::Long   qw(GetOptions);
use File::Path     qw(make_path);
use File::Copy     qw(copy);
use File::Basename qw(dirname);
use POSIX          qw(strftime);

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

my $SYS_PROFILES = "/sys/kernel/security/apparmor/profiles";

sub which {
    my ($bin) = @_;
    for my $dir ( split( /:/, ( $ENV{PATH} // "" ) ) ) {
        my $p = "$dir/$bin";
        return $p if -x $p;
    }
    return undef;
}

sub check_tools {
    for my $tool (qw(aa-complain aa-enforce)) {
        loge("'$tool' is not in PATH. Please install 'apparmor-utils'.")
          unless which($tool);
    }
}

sub check_apparmor_available {
    loge("$SYS_PROFILES does not exist. Is AppArmor enabled/loaded?")
      unless -e $SYS_PROFILES;
}

sub require_root {
    my ($dry) = @_;
    return if $dry;
    loge(
"You must run as root (use sudo) to apply changes. Use --dry-run to simulate."
    ) if $> != 0;
}

sub parse_sys_profiles {
    open my $fh, "<", $SYS_PROFILES or loge("Cannot read $SYS_PROFILES: $!");
    my %enforced;

    while ( my $line = <$fh> ) {
        chomp($line);
        $line =~ s/^\s+|\s+$//g;
        next if $line eq "";

        if ( $line =~ /^(.*)\s+\((enforce|complain|kill)\)\s*$/ ) {
            my ( $name, $mode ) = ( $1, $2 );
            $name =~ s/\s+$//;
            $enforced{$name} = 1 if $mode eq "enforce";
        }
    }

    close $fh;
    return sort keys %enforced;
}

sub write_state_file {
    my ( $state_file, $profiles_ref ) = @_;
    my @profiles = @$profiles_ref;

    my ($dir) = $state_file =~ m|^(.*)/[^/]+$|;
    if ( defined $dir && $dir ne "" && !-d $dir ) {
        make_path($dir) or loge("Cannot create directory $dir: $!");
    }

    if ( -e $state_file ) {
        my $bak =
            "/var/backups"
          . $state_file . ".bak."
          . strftime( "%Y%m%d-%H%M%S", localtime );
        my $bdir = dirname($bak);
        if ( !-d $bdir ) {
            make_path($bdir) or loge("Cannot create backup dir $bdir: $!");
        }
        copy( $state_file, $bak ) or loge("Cannot create backup $bak: $!");
    }

    open my $out, ">", $state_file or loge("Cannot write $state_file: $!");
    my $ts = strftime( "%Y-%m-%d %H:%M:%S", localtime );

    print $out "# AppArmor enforce->complain snapshot\n";
    print $out "# timestamp: $ts\n";
    print $out "# profiles: " . scalar(@profiles) . "\n";
    print $out "# one profile name per line\n\n";
    print $out "$_\n" for @profiles;

    close $out;
}

sub read_state_file {
    my ($state_file) = @_;
    loge("State file does not exist: $state_file") unless -e $state_file;

    open my $fh, "<", $state_file or loge("Cannot read $state_file: $!");
    my @profiles;

    while ( my $line = <$fh> ) {
        chomp($line);
        $line =~ s/^\s+|\s+$//g;
        next if $line eq "";
        next if $line =~ /^#/;
        push @profiles, $line;
    }

    close $fh;
    return @profiles;
}

sub run_cmd {
    my ( $cmd_ref, $dry ) = @_;
    my @cmd = @$cmd_ref;

    if ($dry) {
        logi( "DRY-RUN: " . join( " ", map { /\s/ ? "'$_'" : $_ } @cmd ) );
        return 1;
    }

    system(@cmd);

    if ( $? == -1 ) {
        logw( "FAIL: " . join( " ", @cmd ) . " :: failed to execute: $!" );
        return 0;
    }
    elsif ( $? & 127 ) {
        logw(
            sprintf(
                "FAIL: %s :: died with signal %d",
                join( " ", @cmd ),
                ( $? & 127 )
            )
        );
        return 0;
    }
    else {
        my $rc = $? >> 8;
        if ( $rc != 0 ) {
            logw( "FAIL: " . join( " ", @cmd ) . " :: exit $rc" );
            return 0;
        }
    }

    return 1;
}

sub cmd_downgrade {
    my ( $state_file, $dry ) = @_;

    my @enforced = parse_sys_profiles();
    if ( !@enforced ) {
        logw("No profiles are currently in enforce mode. Nothing to do.");
        return 0;
    }

    write_state_file( $state_file, \@enforced );
    logi(   "Saved enforce-mode profile list to: $state_file ("
          . scalar(@enforced)
          . ") profiles" );

    my $ok = 0;
    for my $p (@enforced) {
        $ok++ if run_cmd( [ "aa-complain", $p ], $dry );
    }

    logi( "Switched to complain: $ok/" . scalar(@enforced) );
    if ( $ok != scalar(@enforced) ) {
        logw("Some profiles could not be switched (see FAIL messages above).");
        return 1;
    }

    return 0;
}

sub cmd_restore {
    my ( $state_file, $dry ) = @_;

    my @to_restore = read_state_file($state_file);
    if ( !@to_restore ) {
        logw("The saved list is empty. Nothing to restore.");
        return 0;
    }

    my $ok = 0;
    for my $p (@to_restore) {
        $ok++ if run_cmd( [ "aa-enforce", $p ], $dry );
    }

    logi( "Restored to enforce: $ok/" . scalar(@to_restore) );
    if ( $ok != scalar(@to_restore) ) {
        logw("Some profiles could not be restored (see FAIL messages above).");
        return 1;
    }

    return 0;
}

sub usage {
    print <<"USAGE";
Usage:
  $0 [--state-file PATH] [--dry-run] downgrade
  $0 [--state-file PATH] [--dry-run] restore

Options:
  --state-file PATH   State file to save/read the list
                      (default: /var/lib/apparmor/enforce_to_complain.list)
  --dry-run           Do not change anything; only print commands
  --help              Show this help

USAGE
    exit(2);
}

my $state_file = "/var/lib/apparmor/enforce_to_complain.list";
my $dry_run    = 0;
my $help       = 0;

GetOptions(
    "state-file=s" => \$state_file,
    "dry-run!"     => \$dry_run,
    "help!"        => \$help,
) or usage();

usage() if $help;

my $cmd = shift @ARGV // "";
usage() unless $cmd eq "downgrade" || $cmd eq "restore";

check_apparmor_available();
check_tools();
require_root($dry_run);

if ( $cmd eq "downgrade" ) {
    exit( cmd_downgrade( $state_file, $dry_run ) );
}
else {
    exit( cmd_restore( $state_file, $dry_run ) );
}
