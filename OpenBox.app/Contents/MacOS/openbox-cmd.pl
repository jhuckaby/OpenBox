#!/usr/bin/perl

##
# OpenBox User Command Script
# Sends commands to running openbox daemon
# Copyright (c) 2011, 2012 Joseph Huckaby <jhuckaby@gmail.com>
# Released under the MIT License.
# 
# Usage:
#	./openbox-cmd.pl --cmd load_prefs
#	./openbox-cmd.pl --project_id 12345 --project_cmd downsync --growl 1
##

use strict;
no strict 'refs';

use FileHandle;
use DirHandle;
use File::Basename;
use File::Path;
use URI::Escape;
use Time::HiRes qw/time sleep/;
use UNIVERSAL qw/isa/;
use Cwd qw/getcwd abs_path/;

chdir dirname($0);
require 'JSON.pm';

$| = 1;

my $args = Args->new(@ARGV);
if (!(scalar keys %$args)) { die "Usage: ./openbox-cmd.pl --cmd COMMAND --key VALUE [--key VALUE ...]\n"; }

my $temp_dir = $ENV{'HOME'} . '/.openbox';
if (!(-d $temp_dir)) {
	die "Temporary directory does not exist: $temp_dir: Cannot run.\n";
}

# default to 'project_delegate' command if not specified
# this sends command to one particular project (child process) instead of parent daemon
$args->{cmd} ||= 'project_delegate';

# load daemon's PID file
my $daemon_pid = load_file( $temp_dir . '/openboxsyncd.pid' ) || '';
chomp $daemon_pid;
if (!$daemon_pid || !kill(0, $daemon_pid)) {
	die "OpenBox Daemon is not running, cannot send command.\n";
}

# write command to PID-specific json file
my $cmd_file = $temp_dir . "/user-command-$daemon_pid.json";
if (!save_file_atomic( $cmd_file, json_compose( { %$args } ) )) {
	die "Could not write command file: $cmd_file: $!\n";
}

# send USR1 signal to daemon, so it loads command file
kill "USR1", $daemon_pid;

# Done!
# print "Command sent.\n";

exit;

sub json_parse {
	return JSON::decode_json( $_[0] );
}

sub json_compose {
	return JSON::encode_json( $_[0] );
}

sub load_file {
	##
	# Loads file into memory and returns contents as scalar.
	##
	my $file = shift;
	my $contents = undef;
	
	my $fh = new FileHandle "<$file";
	if (defined($fh)) {
		$fh->read( $contents, (stat($fh))[7] );
		$fh->close();
	}
	
	##
	# Return contents of file as scalar.
	##
	return $contents;
}

sub save_file {
	##
	# Save file contents
	##
	my ($file, $contents) = @_;

	my $fh = new FileHandle ">$file";
	if (defined($fh)) {
		$fh->print( $contents );
		$fh->close();
		return 1;
	}
	
	return 0;
}

sub save_file_atomic {
	##
	# Save file using atomic operation
	##
	my ($file, $contents) = @_;
	my $temp_file = $file . '.' . $$ . '.tmp';
	
	if (!save_file($temp_file, $contents)) {
		unlink $temp_file;
		return 0;
	}
	
	if (!rename($temp_file, $file)) {
		unlink $temp_file;
		return 0;
	}
	
	return 1;
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
