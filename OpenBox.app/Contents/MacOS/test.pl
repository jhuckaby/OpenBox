#!/usr/bin/perl

package OpenBox;

##
# OpenBox Sync Daemon
# Watches local directory trees and uses rsync to mirror
# Copyright (c) 2011, 2012 Joseph Huckaby <jhuckaby@gmail.com>
# Released under the MIT License.
##

use strict;
no strict 'refs';

use FileHandle;
use DirHandle;
use File::Basename;
use File::Path;
use URI::Escape;
use Time::HiRes qw/time sleep/;
use Data::Dumper;
use IPC::Open2;
use UNIVERSAL qw/isa/;
use Cwd qw/getcwd abs_path/;
use File::Spec::Functions;
use IO::Select;
use POSIX qw/:sys_wait_h setsid/;

my $usage = "Usage: perl test.pl REMOTE_HOSTNAME REMOTE_PASSWORD\n";
my $ssh_hostname = shift @ARGV or die $usage;
my $ssh_password = shift @ARGV or die $usage;

chdir dirname($0);

require 'JSON.pm';
require 'Daemon.pm';
require 'utils.pl';

$SIG{'__DIE__'} = sub {
	unlink "auto";
	Carp::cluck("Stack Trace");
};

my $os_ver = os_detect_auto_lib_setup();
print "OS Version Detected: $os_ver\n";

eval 'use Mac::FSEvents;';
eval 'use IO::Pty::Easy;';

print "All libraries loaded.\n";

# make sure openbox isn't running, or sync daemon
my $temp = `ps -ef | grep -i openbox | grep -v grep`;
if ($temp =~ /\S/) { die "OpenBox is running, please quit it before running the test suite: $temp\n"; }

# clear user's clipboard
`echo "NOTHING" | pbcopy`;

# load config
my $resident = bless( {
	args => Args->new(@ARGV),
	env => \%ENV,
	config => json_parse( load_file( '../Resources/config.json' ) )
} );
my $self = $resident;

# create temp app dir
$resident->{config}->{TempDir} = $ENV{'HOME'} . '/.openbox';
if (!(-d $resident->{config}->{TempDir})) {
	if (!mkdir( $resident->{config}->{TempDir}, 0755 )) {
		die "Failed to create temporary directory: " . $resident->{config}->{TempDir} . ": $1\n";
	}
}

# copy 'security' binary, so we can look good in keychain access
my $sec_trick = $resident->{config}->{TempDir} . '/OpenBox';
if (!(-e $sec_trick)) {
	`cp /usr/bin/security $sec_trick`;
}

# check for necessary files
my $rsync_cmd = $self->{config}->{BaseRsyncCommand}; $rsync_cmd =~ s/\s+.+$//;
if (!(-e $rsync_cmd)) { die "Rsync not found!\n"; }
if (!(-e $self->{config}->{BaseSSHCommand})) { die "SSH not found!\n"; }

# test FSEvents
print "\nTesting FSEvents...\n";
my $temp_name = 'TEST' . time();
my $temp_dir = follow_symlinks('/var/tmp/openboxtest');
`rm -rf $temp_dir`;
`mkdir -p $temp_dir`;

my $fs = Mac::FSEvents->new( {
	path => $temp_dir,
	latency => 0.1
} );

my $fh = $fs->watch;

# Select on this filehandle
my $sel = IO::Select->new($fh);

my $done = 0;
while (!$done) {
	while ( $sel->can_read(1) ) {
		my @events = $fs->read_events;
		for my $event ( @events ) {
			my $path = abs_path( $event->path );
			if (-f $path) { $path = dirname($path); }
			my $base_dir = $temp_dir;
			if ($path && ($path =~ m@^$base_dir@)) {
				print "FSEvent: Directory has changed: $path\n";
				$done = 1;
			}
		} # foreach event
	}
	sleep 0.1;
	# create test file
	`echo foo > $temp_dir/$temp_name.txt`;
}

# notify
print "\nTesting desktop notification -- you should see a thing appear...\n";
my $notify_type = os_detect_notify_type();
print "Notify Type: $notify_type\n";
my $img = abs_path( dirname( getcwd() ) ) . '/Resources/' . 'Icon-Upload-48.png';
my $title = "OpenBox";
my $msg = "This is a test.";

my $growl_cmd = '';
if ($notify_type =~ /growl/) {
	# growl 1.2 or 1.3
	$growl_cmd = $notify_type . ' --image "'.$img.'" --identifier "openboxtest" --message "'.$msg.'" "' . $title . '"';;
}
else {
	# no growl, use cocoadialog bubble
	$growl_cmd = $notify_type . ' bubble --title "'.$title.'" --text "'.$msg.'" --icon-file "'.$img.'" --text-color "ffffff" --border-color "444444" --background-top "000000" --background-bottom "444444" --alpha 0.95 --timeout 5';
}

print "Growling: $growl_cmd\n";
system($growl_cmd . ' >/dev/null 2>&1 &');
sleep 3;

# cocoadialog
print "\nTesting CocoaDialog now...\n";
my $result = $self->call_dialog( 'fileselect', {
	'title' => "Test File Select Dialog",
	'text' => "Select a file for the test:",
	'with-directory' => $ENV{'HOME'}
} );
if (!$result) { die "FAILED TO RECEIVE FILE PATH\n"; }
print "You selected: $result\n";

# rsync + Pty
print "\nTesting IO::Pty and rsync/ssh...\n";
my $username = $ENV{USER};
my $cmd = $self->{config}->{BaseRsyncCommand};
$cmd .= ' -e "';
$cmd .= $self->{config}->{BaseSSHCommand} . ' -l '.$username;
$cmd .= ' ' . $self->{config}->{SSHOptions};
$cmd .= ' -oPasswordAuthentication=yes -oPubkeyAuthentication=no';
$cmd .= '"';
$cmd .= ' --progress --stats --out-format="SENT:%i /%f"';
$cmd .= " $temp_dir $ssh_hostname:/var/tmp";

print "Spawning command: $cmd\n";

my $pty = IO::Pty::Easy->new;
$pty->spawn($cmd . ' 2>&1');
my $sent_pass = 0;

while ($pty->is_active) {
	my $buffer = $pty->read(1, 256);
	$buffer =~ s/\r\n/\n/sg;
	$buffer =~ s/\r/\n/sg;
	
	if (!$sent_pass && ($buffer =~ /\bpassword\:/i)) {
		$self->log_debug(9, "We were prompted for a password, sending it now.");
		$pty->write( $ssh_password . "\n", 0 );
		$sent_pass = 1;
	}
	
	if ($buffer =~ /\S/) {
		print $buffer;
	}
}
if (!$sent_pass) { die "ERROR: We were never sent a password.  Please try the rsync command manually to see what went wrong.\n"; }

# afplay
print "\nTesting afplay (you should hear a sound)...\n";

my $sound_filename = 'sync-end.mp3';
my $sound_file = abs_path( dirname( getcwd() ) ) . '/Resources/sounds/' . $sound_filename;
my $sound_cmd = $self->{config}->{BaseSoundCommand} . ' ' . $sound_file;
$self->log_debug(9, "Playing Sound: $sound_cmd");
system($sound_cmd . ' >/dev/null 2>&1');

# AppleScript
print "\nTesting AppleScript...\n";
$self->call_applescript( join("\n", 
	'tell application "System Events"',
	'activate',
	'display alert "This is a test dialog." as informational',
	'end tell'
) );

# Keychain (/usr/bin/security)
print "\nTesting Apple Keychain...\n";
print "Storing password for openboxtest.com: 12345\n";
if (!$self->store_password_in_keychain( 'pass', $username, 'openboxTEST.com', '12345' )) {
	die "Failed to store password in keychain\n.";
}
print "Trying to fetch stored password...\n";
my $passtest = $self->find_password_in_keychain( 'pass', $username, 'openboxTEST.com' );
if ($passtest ne '12345') { die "Failed to retrieve password from keychain.\n"; }
print "Password sucessfully retrieved!\n";

# copy to clipboard
print "\nTesting copy to clipboard...\n";
my $clip_url = 'http://openbox.io/clip.txt';
$self->log_debug(8, "Copying URL to clipboard: $clip_url");
my $base_clip_cmd = $self->{config}->{BaseClipCommand};
# `echo -n "$clip_url" | $base_clip_cmd`;
my $cfh = FileHandle->new("|$base_clip_cmd");
$cfh->print( $clip_url );
$cfh->close();
sleep 0.1;

$result = $self->call_applescript( join("\n", 
	'tell application "System Events"',
	'activate',
	'display dialog "Something was just copied to your clipboard.  Test by pasting it here." default answer "" with title "Clipboard Test" with icon 1',
	'text returned of result',
	'end tell'
) );
chomp $result;
if ($result =~ /(execution\s+error|User\s+canceled)/) {
	die "$result\n";
}
elsif ($result !~ /\S/) {
	die "User did not enter anything.\n";
}
if ($result ne $clip_url) {
	die "Result does not match what we copied to clipboard: $result\n";
}
print "Clipboard result matches!  YAY!\n";

print "\nAll done. Exiting.\n\n";
unlink "auto";
`rm -rf $temp_dir`;
exit;

sub log_debug {
	my ($self, $level, $msg) = @_;
	print "$msg\n";
}

sub follow_symlinks {
	##
	# Recursively resolve all symlinks in file path
	##
	my $file = shift;
	my $old_dir = getcwd();

	chdir dirname $file;
	while (my $temp = readlink(basename $file)) {
		$file = $temp; 
		chdir dirname $file;
	}
	chdir $old_dir;

	return abs_path(dirname($file)) . '/' . basename($file);
}

1;

package Args;

use strict;

sub new {
	##
	# Class constructor method
	##
	my $self = bless {}, shift;
	my @input = @_;
	if (!@input) { @input = @ARGV; }
	
	my $mode = undef;
	my $key = undef;
	
	while (defined($key = shift @input)) {
		if ($key =~ /^\-*(\w+)=(.+)$/) { $self->{$1} = $2; next; }
		
		my $dash = 0;
		if ($key =~ s/^\-+//) { $dash = 1; }

		if (!defined($mode)) {
			$mode = $key;
		}
		else {
			if ($dash) {
				if (!defined($self->{$mode})) { $self->{$mode} = 1; }
				$mode = $key;
			} 
			else {
				if (!defined($self->{$mode})) { $self->{$mode} = $key; }
				else { $self->{$mode} .= ' ' . $key; }
			} # no dash
		} # mode is 1
	} # while loop

	if (defined($mode) && !defined($self->{$mode})) { $self->{$mode} = 1; }

	return $self;
}

1;

