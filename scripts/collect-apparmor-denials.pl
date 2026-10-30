#!/usr/bin/perl

# Collect AppArmor-related journal and audit events from the last 30 days.
# The full event log and a grouped summary are written under
# /var/log/apparmor-denials with root:adm ownership when the adm group exists.
#
# Run as root. The script does not change AppArmor policy or service state.
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

use strict;
use warnings;

use Fcntl      qw(:mode);
use File::Temp qw(tempfile);
use IO::Select;
use IPC::Open3;
use POSIX  qw(strftime);
use Symbol qw(gensym);

my $LOG_DIR     = '/var/log/apparmor-denials';
my $FULL_LOG    = "$LOG_DIR/apparmor-denials-last-30-days.log";
my $SUMMARY_LOG = "$LOG_DIR/apparmor-denials-summary.log";
my $RANGE_DAYS  = 30;

# Track staged outputs so a failed write does not leave partial report files.
my @TEMP_FILES;

$ENV{PATH}   = '/usr/sbin:/usr/bin:/sbin:/bin';
$ENV{LC_ALL} = 'C';
$ENV{LANG}   = 'C';

sub logi { print "[INFO] $_[0]\n"; }
sub loge { print STDERR "[ERROR] $_[0]\n"; }

sub command_result {
    my (@command) = @_;
    my $stderr = gensym();
    my ( $stdout, $pid );

   # Pass fixed argument lists directly; never interpret log data as shell text.
    eval { $pid = open3( undef, $stdout, $stderr, @command ); 1 }
      or die "cannot start $command[0]: $@";

   # Drain both pipes concurrently so a full stderr pipe cannot block the child.
    my $selector  = IO::Select->new( $stdout, $stderr );
    my $stdout_fd = fileno($stdout);
    my $stderr_fd = fileno($stderr);
    my %stream    = ( $stdout_fd => '', $stderr_fd => '' );

    while ( $selector->count ) {
        for my $fh ( $selector->can_read() ) {
            my $fd   = fileno($fh);
            my $read = sysread( $fh, my $chunk, 8192 );
            if ( !defined $read ) {
                next if $!{EINTR};
                die "cannot read output from $command[0]: $!";
            }
            if ( $read == 0 ) {
                $selector->remove($fh);
                close $fh;
                next;
            }
            $stream{$fd} .= $chunk;
        }
    }

    waitpid( $pid, 0 ) == $pid or die "cannot wait for $command[0]: $!";
    my $status = $? == -1 ? 255 : ( $? & 127 ? 128 + ( $? & 127 ) : $? >> 8 );
    return ( $stream{$stdout_fd} // '', $stream{$stderr_fd} // '', $status );
}

sub checked_output {
    my ( $label, @command ) = @_;
    my ( $stdout, $stderr, $status ) = command_result(@command);
    die "$label failed with exit status $status: $stderr" if $status != 0;
    return $stdout;
}

# Optional metadata commands may be absent or fail without aborting collection.
sub optional_output {
    my (@command) = @_;
    my ( $stdout, $stderr, $status ) = command_result(@command);
    return 'unavailable' if $status != 0;
    my $output = length($stdout) ? $stdout : $stderr;
    $output =~ s/\A\s+|\s+\z//g;
    $output =~ s/[\x00-\x1f\x7f]/ /g;
    return length($output) ? $output : 'unavailable';
}

sub command_exists {
    my ($name) = @_;
    for my $directory ( split /:/, $ENV{PATH} ) {
        my $path = "$directory/$name";
        return $path if -f $path && -x _;
    }
    return;
}

sub ensure_log_directory {
    my @group    = getgrnam('adm');
    my $group_id = @group ? $group[2] : 0;

    if ( -e $LOG_DIR || -l $LOG_DIR ) {
        my @metadata = lstat($LOG_DIR);

        # Refuse a symlink here because this process writes reports as root.
        die "$LOG_DIR is not a real directory"
          if !@metadata
          || !S_ISDIR( $metadata[2] )
          || S_ISLNK( $metadata[2] );
        die "$LOG_DIR is not owned by root" if $metadata[4] != 0;
    }
    else {
        mkdir $LOG_DIR, 0750 or die "cannot create $LOG_DIR: $!";
    }

    chown 0, $group_id, $LOG_DIR or die "cannot set ownership on $LOG_DIR: $!";
    chmod 0750, $LOG_DIR or die "cannot set permissions on $LOG_DIR: $!";
    return $group_id;
}

sub sanitize_text {
    my ($text) = @_;

    # Keep control characters from forging extra report rows or terminal output.
    $text =~ s/([\x00-\x08\x0b-\x1f\x7f])/sprintf '\\x%02x', ord($1)/ge;
    return $text;
}

sub collect_matching_lines {
    my ( $text, $seen_ref ) = @_;
    my @lines;

    for my $line ( split /\n/, $text ) {
        $line =~ s/\r\z//;

      # Retain AppArmor fields while filtering unrelated journal and audit data.
        next
          if $line !~
          /(?:apparmor="|operation=|profile=|requested_mask=|denied_mask=)/i;
        $line = sanitize_text($line);
        next if $seen_ref->{$line}++;
        push @lines, $line;
    }
    return @lines;
}

sub field_value {
    my ( $line, $field ) = @_;
    if ( $line =~ /(?:^|\s)\Q$field\E="((?:\\.|[^"\\])*)"/ ) {
        my $value = $1;
        $value =~ s/\\(["\\])/$1/g;
        $value =~ s/[\t\r\n]/ /g;
        return $value;
    }
    return '-';
}

# Prefer the explicit AppArmor status field, then infer a label from event text.
sub event_status {
    my ($line) = @_;
    my $status = field_value( $line, 'apparmor' );
    return $status   if $status ne '-';
    return 'DENIED'  if $line =~ /DENIED/i;
    return 'ALLOWED' if $line =~ /ALLOWED/i;
    return 'STATUS'  if $line =~ /STATUS/i;
    return 'AVC'     if $line =~ /AVC/i;
    return '-';
}

sub summarize_events {
    my (@events) = @_;
    my %counts;

    for my $line (@events) {

      # Group events by the fields most useful for identifying repeated denials.
        my @fields = (
            event_status($line),
            field_value( $line, 'profile' ),
            field_value( $line, 'comm' ),
            field_value( $line, 'operation' ),
            field_value( $line, 'name' ),
            field_value( $line, 'denied_mask' ),
            field_value( $line, 'requested_mask' ),
        );
        $counts{ join "\x1e", @fields }++;
    }

    my $summary =
"count\tstatus\tprofile\tcomm\toperation\tname\tdenied_mask\trequested_mask\n";
    for
      my $key ( sort { $counts{$b} <=> $counts{$a} || $a cmp $b } keys %counts )
    {
        $summary .=
          $counts{$key} . "\t" . join( "\t", split /\x1e/, $key, -1 ) . "\n";
    }
    return $summary;
}

sub write_temporary_report {
    my ( $contents, $group_id ) = @_;
    my ( $fh,       $path )     = tempfile(
        '.collect-apparmor-denials.XXXXXX',
        DIR    => $LOG_DIR,
        UNLINK => 0,
    );
    push @TEMP_FILES, $path;

   # Create the temporary file inside LOG_DIR so rename stays on one filesystem.
    binmode $fh           or die "cannot set raw mode on $path: $!";
    print {$fh} $contents or die "cannot write $path: $!";
    close $fh             or die "cannot close $path: $!";
    chown 0, $group_id, $path or die "cannot set ownership on $path: $!";
    chmod 0640, $path or die "cannot set permissions on $path: $!";
    return $path;
}

sub main {
    die "must be run as root\n" if $> != 0;

    for my $command (qw(journalctl date uname hostname apparmor_parser)) {
        die "required command not found: $command\n"
          if !command_exists($command);
    }

    my $group_id = ensure_log_directory();
    my $run_time = strftime( '%Y-%m-%dT%H:%M:%S%z', localtime() );
    my $host     = optional_output('hostname');
    my $kernel   = checked_output( 'uname', 'uname', '-srvmo' );
    $kernel =~ s/\s+\z//;
    my $parser = optional_output( 'apparmor_parser', '--version' );
    my $package =
        command_exists('dpkg-query')
      ? optional_output( 'dpkg-query', '-W', '-f=${Version}', 'apparmor' )
      : 'unavailable';

    # ausearch expects the locale date and time as separate arguments. Its
    # date parser accepts a two-digit year here; a four-digit year is rejected
    # by the audit-userspace version shipped on Debian 13.
    my $since_audit =
      checked_output( 'date', 'date', '-d', "$RANGE_DAYS days ago",
        '+%m/%d/%y %T' );
    $since_audit =~ s/\s+\z//;
    my ( $since_audit_date, $since_audit_time ) = split /\s+/, $since_audit, 2;
    die "date returned an invalid ausearch start time: $since_audit\n"
      if !defined($since_audit_date) || !defined($since_audit_time);

# Query the journal once, then apply the same AppArmor-field filter to audit data.
    my ( $journal, $journal_error, $journal_status ) = command_result(
        'journalctl',           '--since',
        "$RANGE_DAYS days ago", '--no-pager',
        '--output=short-iso-precise'
    );
    die "journalctl failed with exit status $journal_status: $journal_error"
      if $journal_status != 0;

    my @journal_events = collect_matching_lines( $journal, {} );
    my @audit_events;
    my $audit_available = command_exists('ausearch') ? 1 : 0;
    if ($audit_available) {

        # ausearch uses status 1 for an empty match as well as minor errors;
        # accept it only when both output streams are empty.
        my %audit_seen;
        for
          my $message_type ( 'AVC,USER_AVC,APPARMOR_DENIED', 'APPARMOR_DENIED' )
        {
            my ( $output, $error, $status ) =
              command_result( 'ausearch', '-m', $message_type, '-ts',
                $since_audit_date, $since_audit_time );
            if (   $status == 1
                && !length($output)
                && ( !length($error) || $error =~ /\A\s*<no matches>\s*\z/ ) )
            {
                next;
            }
            die "ausearch failed with exit status $status: $error"
              if $status != 0;
            push @audit_events, collect_matching_lines( $output, \%audit_seen );
        }
    }

  # Deduplicate identical records that appear in both journald and audit output.
    my %combined_seen;
    my @combined = (
        collect_matching_lines(
            join( "\n", @journal_events ), \%combined_seen
        ),
        collect_matching_lines( join( "\n", @audit_events ), \%combined_seen ),
    );
    my $full = join(
        "\n",
        '# AppArmor event collection',
        "# generated: $run_time",
        "# host: " . sanitize_text($host),
        "# kernel: " . sanitize_text($kernel),
        "# apparmor_parser: " . sanitize_text($parser),
        "# apparmor_package: " . sanitize_text($package),
        "# range: last $RANGE_DAYS days",
        '# journald_matches: ' . scalar(@journal_events),
        '# auditd_matches: ' . scalar(@audit_events),
        "# auditd_available: $audit_available",
'# filters: apparmor=, operation=, profile=, requested_mask=, denied_mask=',
        '',
        @combined
        ? ( '# matching events', @combined )
        : ('# no matching AppArmor-related events found in the requested range'
        ),
    ) . "\n";
    my $summary = join( "\n",
        '# AppArmor event summary',
        "# generated: $run_time",
        "# host: " . sanitize_text($host),
        "# kernel: " . sanitize_text($kernel),
        "# apparmor_parser: " . sanitize_text($parser),
        "# apparmor_package: " . sanitize_text($package),
        "# range: last $RANGE_DAYS days",
        '# events_considered: ' . scalar(@combined),
        '',
        @combined
        ? summarize_events(@combined)
        : ('No matching AppArmor-related events found in the requested range.'),
    ) . "\n";

    # Stage both reports before replacing either existing report.
    my $full_tmp    = write_temporary_report( $full,    $group_id );
    my $summary_tmp = write_temporary_report( $summary, $group_id );

    # Replace prior reports atomically instead of truncating files in place.
    rename $full_tmp, $FULL_LOG
      or die "cannot replace $FULL_LOG: $!";
    rename $summary_tmp, $SUMMARY_LOG
      or die "cannot replace $SUMMARY_LOG: $!";

    logi(   'wrote '
          . scalar(@combined)
          . " AppArmor-related event(s) to $LOG_DIR" );
    return 0;
}

END {
    unlink $_ for grep { defined && -e $_ } @TEMP_FILES;
}

my $ok = eval { main(); 1 };
if ( !$ok ) {
    my $error = $@ || 'unknown failure';
    $error =~ s/\s+\z//;
    loge($error);
    exit 1;
}

exit 0;
