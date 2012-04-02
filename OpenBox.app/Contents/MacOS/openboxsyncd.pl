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

chdir dirname($0);
require 'JSON.pm';
require 'Daemon.pm';
require 'utils.pl';
eval 'use Mac::FSEvents;';
eval 'use IO::Pty::Easy;';

# $| = 1;

##
# Load configuration
##
my $resident = bless( {
	args => Args->new(@ARGV),
	env => \%ENV,
	config => json_parse( load_file( '../Resources/config.json' ) )
} );

# hard-code temp dir to user-specific one, and auto-create it if necessary
$resident->{config}->{TempDir} = $ENV{'HOME'} . '/.openbox';
if (!(-d $resident->{config}->{TempDir})) {
	if (!mkdir( $resident->{config}->{TempDir}, 0755 )) {
		die "Failed to create temporary directory: " . $resident->{config}->{TempDir} . ": $1\n";
	}
}

my $info_plist = load_file( '../Info.plist' );
my $bundle_name = 'OpenBoxSync';
# if ($info_plist =~ m@<key>CFBundleName</key>\s+<string>(.+?)</string>@) { $bundle_name = $1; }
my $process_name = $bundle_name; $process_name =~ s/\W+//g;

$resident->{bundle_name} = $bundle_name;
$resident->{process_name} = $process_name;

my $bundle_id = 'com.unknown.app';
if ($info_plist =~ m@<key>CFBundleIdentifier</key>\s+<string>(.+?)</string>@) { $bundle_id = $1; }
$resident->{bundle_id} = $bundle_id;

$resident->{projects} = [];

$resident->{prefs_file} = $ENV{'HOME'} . '/Library/Preferences/' . $resident->{bundle_id} . '.json';
$resident->load_prefs();

# cleanup old status files from deleted projects
foreach my $temp_file (glob($resident->{config}->{TempDir} . '/project-status-*.json')) {
	if ($temp_file =~ /project\-status\-(\w+)\.json$/) {
		my $project_id = $1;
		if (!find_object($resident->{prefs}->{projects}, { id => $project_id })) {
			unlink $temp_file;
		}
	}
}

# see if we have growl 1.2 (free), growl 1.3 (paid) or neither (will use CocoaDialog in that case)
my $ps_raw = `ps -ef`;
my $notify_type = '';
if ($ps_raw =~ /Growl\.app/) { $notify_type = './growlnotify-1.3'; }
elsif ($ps_raw =~ /GrowlHelperApp\.app/) { $notify_type = './growlnotify-1.2'; }
else { $notify_type = './CocoaDialog/Contents/MacOS/CocoaDialog'; }
$resident->{notify_type} = $notify_type;

##
# Setup preforking HTTP server
##
my $daemon = $resident->{daemon} = Daemon->new(
	name => $bundle_name,
	process_name => $process_name,
	pid_file => $resident->{config}->{TempDir} . "/openboxsyncd.pid",
	# stop_file => $resident->{config}->{TempDir} . "/openboxsyncd.stop",
	debug_level => $resident->{config}->{DebugLevel},
	no_fork => 1,
	no_socket => 1,
	logger => $resident,
	growl => '',
	port => 0,
	max_children => 0, # no http children (not a http server)
	max_requests_per_child => 0,
	idle_handler => \&idle,
	idle_time => 1.0
);

# Ctrl-C handler, so we exit gracefully
$SIG{INT} = sub { $daemon->{sig_term} = 1; };
$SIG{HUP} = sub { $daemon->{sig_term} = 1; };
$SIG{USR1} = sub { $daemon->{sig_usr1} = 1; };

# Make sure stop file is deleted (API can create it for us to exit).
# unlink $daemon->{stop_file};

# copy 'security' binary, so we can look good in keychain access
my $sec_trick = $resident->{config}->{TempDir} . '/OpenBox';
if (!(-e $sec_trick)) {
	`cp /usr/bin/security $sec_trick`;
}

$daemon->startup();
$daemon->idle();

# cleanup
# unlink $daemon->{stop_file};

exit;

sub idle {
	##
	# Called in daemon proc every 1 second
	##
	my $daemon = shift;
	my $self = $resident;
	
	if (!$self->{startup_monitor_check}) {
		$self->{startup_monitor_check} = 1;
		$self->monitor_projects();
	}
	# $self->monitor_prefs();
	
	if ($daemon->{sig_usr1}) {
		delete $daemon->{sig_usr1};
		my $cmd_file = $self->{config}->{TempDir} . "/user-command-$$.json";
		$self->log_debug(3, "Caught SIGUSR1, loading command file: $cmd_file");
		
		if (-f $cmd_file) {
			my $json_raw = load_file($cmd_file);
			$self->log_debug(9, "Raw command json: $json_raw");
			
			my $json = undef;
			eval { $json = json_parse( $json_raw ); };
			unlink $cmd_file;
			
			if ($json) {
				my $func = 'daemon_cmd_' . ($json->{cmd} || 'UNKNOWN');
				if ($self->can($func)) { $self->$func($json); }
				else { $self->log_debug(3, "Unsupported API: $func"); }
			}
			else { $self->log_debug(3, "JSON error in command file: $cmd_file: $@"); }
		}
		else { $self->log_debug(3, "File not found: $cmd_file"); }
	}
	
	# Check for STOP file
	# if (-e $daemon->{stop_file}) {
	#	$self->log_debug(2, "Found STOP file, shutting down now!");
	#	$daemon->{sig_term} = 1;
	#	unlink $daemon->{stop_file};
	# }
}

sub daemon_cmd_test {
	# test command
	my ($self, $json) = @_;
	$self->log_debug(2, "Test");
}

sub daemon_cmd_shutdown {
	# test command
	my ($self, $json) = @_;
	$self->log_debug(2, "Caught user shutdown signal");
	$daemon->{sig_term} = 1;
}

sub daemon_cmd_load_prefs {
	# force daemon (and all children) to reload prefs file
	my ($self, $json) = @_;
	$self->log_debug(2, "Reloading prefs all around");
	
	# mark active children so we know which to send signals to
	foreach my $project (@{$self->{projects}}) {
		if ($project->{pid}) {
			$project->{_send_load_prefs} = 1;
		}
	}
	
	# reload prefs ourselves first (projects may have changed)
	$self->{prefs}->{_CheckTime} = 0;
	$self->monitor_prefs();
	
	# now, manage projects with new prefs
	$self->{last_maint_check} = 0;
	$self->monitor_projects();
	
	# finally, send signals to remaining children who were not deleted, and are not new
	foreach my $project (@{$self->{projects}}) {
		if ($project->{pid} && $project->{_send_load_prefs}) {
			$self->daemon_cmd_project_delegate({
				project_id => $project->{id},
				project_cmd => 'load_prefs'
			});
		}
		delete $project->{_send_load_prefs};
	}
}

sub daemon_cmd_project_delegate {
	# user command to delegate json to project child
	my ($self, $json) = @_;
	$self->log_debug(4, "Delegating ".$json->{project_cmd}." command to project: " . $json->{project_id});
	
	my $project = find_object($self->{projects}, { id => $json->{project_id} });
	if ($project && $project->{pid}) {
		my $pid = $project->{pid};
		my $project_cmd_file = $self->{config}->{TempDir} . "/user-command-$pid.json";
		save_file_atomic( $project_cmd_file, json_compose($json) );
		kill "USR1", $pid;
	}
	else {
		$self->log_debug(3, "Project not found or is not active: " . $json->{project_id});
	}
}

sub monitor_projects {
	# monitor all active projects, perform rsync actions as needed
	my $self = shift;
	my $now = time();
	$self->{prefs}->{projects} ||= [];
	
	# project maintenance (added / removed projects from the UI)
	if (!$self->{last_maint_check} || (($now - $self->{last_maint_check}) >= $self->{config}->{ProjectMaintInterval})) {
		$self->{last_maint_check} = $now;
		
		# look for removed projects
		my $need_delete = 0;
		foreach my $project (@{$self->{projects}}) {
			if (!find_object($self->{prefs}->{projects}, { id => $project->{id} })) {
				$self->log_debug(2, "Project removed: " . $project->{id});
				$project->{deleted} = 1;
				if ($project->{pid}) {
					$self->log_debug( 2, "Killing project child: " . $project->{pid} );
					kill( 1, $project->{pid} ); # SIGTERM
					delete $project->{pid};
				}
				$need_delete = 1;
			}
		}
		if ($need_delete) {
			# rebuild project array without deleted projects
			my $new_projects = [];
			foreach my $project (@{$self->{projects}}) {
				if (!$project->{deleted}) { push @$new_projects, $project; }
			}
			$self->{projects} = $new_projects;
		}
		
		# look for new projects
		foreach my $pprefs (@{$self->{prefs}->{projects}}) {
			if (!find_object($self->{projects}, { id => $pprefs->{id} })) {
				$self->log_debug(2, "Adding new project: " . $pprefs->{id});
			
				my $project = {
					id => $pprefs->{id},
					prefs => $pprefs
				};
			
				push @{$self->{projects}}, $project;
			} # new project
		} # foreach project in prefs
		
		# spawn or kill children as needed
		foreach my $project (@{$self->{projects}}) {
			if ($project->{prefs}->{enabled} && !$project->{pid}) {
				# need to spawn child
				$self->preload_project_passwords( $project );
				$self->log_debug(3, "Forking child for project: " . $project->{id});
				$project->{pid} = $daemon->spawn_custom( sub {
					my ($daemon, $project) = @_;
					$self->watch_project( $project );
					exit();
				}, $project );
			}
			elsif (!$project->{prefs}->{enabled} && $project->{pid}) {
				# need to kill child, project is now disabled
				$self->log_debug(3, "Killing child for disabled project: " . $project->{id} . ": " . $project->{pid});
				kill( 1, $project->{pid} ); # SIGTERM
				delete $project->{pid};
			}
		} # foreach project
	} # maint check
}

sub setup_project {
	# setup monitoring for project
	# called at child startup, and prefs reload
	my ($self, $project) = @_;
	my $prefs = $project->{prefs};
	delete $project->{last_error};
	
	# normalize base dir
	$prefs->{local_base_dir} = abs_path( $prefs->{local_base_dir} );
	
	# setup exclude files
	$self->setup_filters( $project );
	
	# Check for special two-way-delete use case:
	# If user has just enabled auto-downsync AND delete for the first time, force an initial
	# two-way sync WITHOUT delete, then turn it back on.  This is a safety measure.
	my $two_way_safety = 0;
	my $old_startup_sync = $prefs->{startup_sync};
	if (unlink($self->{config}->{TempDir} . '/two-way-delete-safety-'.$project->{id}.'.txt') && $prefs->{auto_downsync} && $prefs->{rsync_delete}) {
		$self->log_debug(1, "Detected two-way delete safety flag: Performing intital two-way sync WITHOUT delete, then will turn it back on."); 
		$prefs->{rsync_delete} = 0;
		$prefs->{startup_sync} = 1;
		$two_way_safety = 1;
	}
	
	if ($prefs->{startup_sync}) {
		# rsync dry-run first, to get file count
		my ($need_rsync, $num_files) = $self->rsync_dry_count( $project, $prefs->{local_base_dir} );
		if ($project->{last_error}) {
			$self->log_debug(4, "Setting error flag for periodic upsync retry");
			$project->{last_upsync_retry} = time();
		}
	
		# one-time rsync refresh of whole project
		if ($need_rsync) {
			$self->rsync( $project, $prefs->{local_base_dir}, $num_files );
		}
	
		# if auto_downsync is enabled, do that now too (before local snapshot)
		if ($prefs->{auto_downsync}) {
			($need_rsync, $num_files) = $self->rsync_dry_count( $project, $prefs->{local_base_dir}, 'downsync' );
			if ($need_rsync) {
				$self->rsync( $project, $prefs->{local_base_dir}, $num_files, 'downsync' );
			}
			$project->{last_auto_downsync} = time();
		} # auto_downsync
	} # startup_sync
	else {
		if ($prefs->{auto_downsync}) { $project->{last_auto_downsync} = time(); }
	}
	
	# clean up two-way safety sync stuff
	# (unless error occurred, in which case leave delete off, as user will likely have to re-save prefs to fix it, hopefully)
	if ($two_way_safety) {
		if (!$project->{last_error}) {
			# only re-enable delete mode if no error occurred during safety sync
			$prefs->{rsync_delete} = 1;
		}
		else {
			# if we got here, this is really unfortunate: an error occured during the two-way safety pre-delete sync.
			# let's recreate the safety flag file, so hopefully when user re-saves it will run the safe sync again
			$self->log_debug(5, "Re-creating two-way safety delete flag for project: " . $project->{id});
			save_file( $self->{config}->{TempDir} . '/two-way-delete-safety-'.$project->{id}.'.txt', '1' );
		}
		$prefs->{startup_sync} = $old_startup_sync;
	}
	
	# take snapshot of all files and folders, for comparison
	$project->{files} = $self->scan_dir( $project, $prefs->{local_base_dir} );
}

sub watch_project {
	# watch project (in child fork)
	# this blocks at $fs->read_events
	my ($self, $project) = @_;
	my $prefs = $project->{prefs};
	
	# must deteach from tty for SSH_ASKPASS
	setsid();
	open( STDIN, "</dev/null" );
	open( STDOUT, ">/dev/null" );
	
	$SIG{TERM} = sub { $self->log_debug(2, "Caught SIGTERM!"); $self->{daemon}->{sig_term} = 1; };
	
	$project->{status_file} = $self->{config}->{TempDir} . '/project-status-' . $project->{id} . '.json';
	$project->{last_rsync_result} = '';
		
	$self->setup_project( $project );
	
	$self->log_debug(3, "Watching fileystem for changes in project: " . $project->{id} . " (" . $prefs->{local_base_dir} . ")");
	
	my $fs = Mac::FSEvents->new( {
		path => $prefs->{local_base_dir},
		latency => 0.1
	} );
	
	my $fh = $fs->watch;
	
	# Select on this filehandle
	my $sel = IO::Select->new($fh);
	
	while (1) {
		while ( $sel->can_read(1) ) {
			my @events = $fs->read_events;
			for my $event ( @events ) {
				my $path = abs_path( $event->path );
				if (-f $path) { $path = dirname($path); }
				my $base_dir = $prefs->{local_base_dir};
				if ($path && ($path =~ m@^$base_dir@)) {
					$self->log_debug(8, "FSEvent: Directory has changed: $path");
					$self->check_dir( $project, $path );
				}
				last if $self->{daemon}->{sig_term};
			} # foreach event
			last if $self->{daemon}->{sig_term};
		}
		
		# $self->monitor_prefs();
				
		# check for user signal
		if ($self->{daemon}->{sig_usr1}) {
			delete $self->{daemon}->{sig_usr1};
			$self->handle_project_user_signal( $project );
		}
		
		last if $self->{daemon}->{sig_term};
		
		# check if project needs a refresh (prefs reloaded)
		if ($project->{refresh}) {
			delete $project->{last_upsync_retry};
			$self->log_debug(3, "Refreshing project: " . $project->{id});
			$self->setup_project( $project );
			$self->log_debug(3, "Returning to event loop");
			delete $project->{refresh};
			$prefs = $project->{prefs}; # must do this, as prefs object was replaced
		} # refresh
		
		last if $self->{daemon}->{sig_term};
		
		# if project is in an error state, retry from time to time
		my $now = time();
		if ($project->{last_upsync_retry} && ($now - $project->{last_upsync_retry} >= $self->{config}->{UpsyncRetryInterval})) {
			$project->{last_upsync_retry} = $now;
			$self->log_debug(4, "Retrying base upsync after previous error");
			
			delete $project->{last_error};
			$self->rsync( $project, $prefs->{local_base_dir}, 0 );
			
			if (!$project->{last_error}) {
				$self->log_debug(4, "Success, removing error retry flag");
				delete $project->{last_upsync_retry};
			}
		} # error retry
		
		last if $self->{daemon}->{sig_term};
		
		# handle auto_downsync
		$now = time();
		if ($prefs->{auto_downsync} && !$project->{last_upsync_retry} && 
			(($now - $project->{last_auto_downsync}) >= ($prefs->{auto_downsync_interval} || $self->{config}->{AutoDownsyncInterval}))) {
			
			$self->log_debug(4, "Performing auto downsync");
			my $num_sent = $self->rsync( $project, $prefs->{local_base_dir}, 0, 'downsync' );
			if ($num_sent) {
				$project->{files} = $self->scan_dir( $project, $prefs->{local_base_dir} );
			}
			$self->log_debug(4, "Auto downsync complete, returning to event loop");
			$project->{last_auto_downsync} = time();
		} # time for downsync fun!
		
		last if $self->{daemon}->{sig_term};
	} # infinite loop
	
	$self->log_debug(3, "Caught SIGTERM, shutting down.");
	
	if ($project->{include_temp_file}) { unlink $project->{include_temp_file}; }
	if ($project->{exclude_temp_file}) { unlink $project->{exclude_temp_file}; }
	# if ($project->{status_file}) { unlink $project->{status_file}; }
}

sub handle_project_user_signal {
	# handle user signal in child process
	my ($self, $project) = @_;
	
	my $cmd_file = $self->{config}->{TempDir} . "/user-command-$$.json";
	$self->log_debug(3, "Caught SIGUSR1, loading command file: $cmd_file");
	if (-f $cmd_file) {
		my $json_raw = load_file($cmd_file);
		$self->log_debug(9, "Raw command json: $json_raw");
		
		my $json = undef;
		eval { $json = json_parse( $json_raw ); };
		unlink $cmd_file;
		
		if ($json) {
			my $func = 'project_cmd_' . ($json->{project_cmd} || 'UNKNOWN');
			if ($self->can($func)) { $self->$func($project, $json); }
			else { $self->log_debug(3, "Unsupported command: $func"); }
		}
		else { $self->log_debug(3, "JSON error in command file: $cmd_file: $@"); }
	}
	else { $self->log_debug(3, "File not found: $cmd_file"); }
}

sub project_cmd_sync {
	# handle upsync (and possibly downsync) user signal
	my ($self, $project, $json) = @_;
	my $prefs = $project->{prefs};
	
	if ($self->project_cmd_upsync( $project, $json )) {
		# no error, check for auto_downsync
		if ($prefs->{auto_downsync}) {
			$self->project_cmd_downsync( $project, $json );
		}
	}
}

sub project_cmd_downsync {
	# handle downsync user signal
	my ($self, $project, $json) = @_;
	my $prefs = $project->{prefs};
	delete $project->{last_error};
	
	# if user wants lots of growling, reset last_rsync_result so we get an error growl
	if ($json->{growl}) { $project->{last_rsync_result} = ''; }
	
	$self->log_debug(3, "Performing downsync");
	if ($json->{growl}) { $self->growl( $project, $self->{config}->{DownloadIcon}, "Performing downward sync..." ); }
	
	# rsync dry-run first, to get file count
	my ($need_rsync, $num_files) = $self->rsync_dry_count( $project, $prefs->{local_base_dir}, 'downsync' );
	if ($project->{last_error}) {
		$self->log_debug(3, "Aborting downsync due to error condition");
		return 0;
	}
	
	# rsync refresh of whole project, downward
	if ($need_rsync) {
		my $num_sent = $self->rsync( $project, $prefs->{local_base_dir}, $num_files, 'downsync' );
		
		# if no files modified and $json->{growl} and no error, growl here, because rsync() won't
		if (!$num_sent && $json->{growl} && !$project->{last_error}) {
			$self->growl( $project, $self->{config}->{DownloadIcon}, "No files were modified." );
			$self->play_sound( $project, 'sync_end' );
		}
		
		# in case anything changed locally, take a new snapshot of all files and folders
		# this prevents a useless fsevent trigger upsync right after
		$project->{files} = $self->scan_dir( $project, $prefs->{local_base_dir} );
	}
	elsif ($json->{growl}) {
		$self->growl( $project, $self->{config}->{DownloadIcon}, "No files were modified." );
		$self->play_sound( $project, 'sync_end' );
	}
	
	$self->log_debug(3, "Downsync complete");
	return 1;
}

sub project_cmd_upsync {
	# handle upsync user signal
	my ($self, $project, $json) = @_;
	my $prefs = $project->{prefs};
	delete $project->{last_error};
	
	# if user wants lots of growling, reset last_rsync_result so we get an error growl
	if ($json->{growl}) { $project->{last_rsync_result} = ''; }
	
	$self->log_debug(3, "Performing upsync");
	if ($json->{growl}) { $self->growl( $project, $self->{config}->{UploadIcon}, "Performing upward sync..." ); }
	
	# rsync dry-run first, to get file count
	my ($need_rsync, $num_files) = $self->rsync_dry_count( $project, $prefs->{local_base_dir} );
	if ($project->{last_error}) {
		$self->log_debug(3, "Aborting upsync due to error condition");
		return 0;
	}
	
	# rsync refresh of whole project, downward
	if ($need_rsync) {
		my $num_sent = $self->rsync( $project, $prefs->{local_base_dir}, $num_files );
		
		# if no files modified and $json->{growl} and no error, growl here, because rsync() won't
		if (!$num_sent && $json->{growl} && !$project->{last_error}) {
			$self->growl( $project, $self->{config}->{UploadIcon}, "No files were modified." );
			$self->play_sound( $project, 'sync_end' );
		}
	}
	elsif ($json->{growl}) {
		$self->growl( $project, $self->{config}->{UploadIcon}, "No files were modified." );
		$self->play_sound( $project, 'sync_end' );
	}
	
	$self->log_debug(3, "Upsync complete");
}

sub project_cmd_load_prefs {
	# handle load_prefs user signal (from UI)
	my ($self, $project, $json) = @_;
	$self->log_debug(3, "Reloading prefs");
	
	# $self->{prefs}->{_CheckTime} = 0;
	# $self->monitor_prefs();
		
	my $prefs_raw = load_file($self->{prefs_file});
	if ($prefs_raw) {
		my $prefs = undef;
		eval { $prefs = json_parse( $prefs_raw ); };
		if (!$@ && $prefs) {
			$self->{prefs} = $prefs;
			
			# save old mod date, for comparison
			my $old_mod_date = $project->{prefs}->{mod_date} || 0;
			
			$project->{prefs} = find_object( $self->{prefs}->{projects}, { id => $project->{id} } );
			if (!$project->{prefs}) { $project->{prefs} = { enabled => 0 }; }
						
			if (!$project->{prefs}->{enabled}) {
				$self->log_debug( 2, "Project is disabled, exiting now." );
				$self->{daemon}->{sig_term} = 1;
			}
			elsif (!$prefs->{daemon_enabled}) {
				$self->log_debug( 2, "Master switch is off, exiting now." );
				$self->{daemon}->{sig_term} = 1;
			}
			else {
				# copy passwords from cache as needed
				$self->{password_cache} ||= {};
				my $password_cache = $self->{password_cache};
				
				if ($project->{prefs}->{rsync_password} && ($project->{prefs}->{rsync_password} eq '_OB_KEYCHAIN_')) {
					my $cache_id = join('|', 'pass', $project->{prefs}->{rsync_username}, $project->{prefs}->{remote_hostname});
					$project->{prefs}->{rsync_password} = $password_cache->{$cache_id} || 'FAIL';
				}
				elsif ($project->{prefs}->{rsync_ssh_key_passphrase} && ($project->{prefs}->{rsync_ssh_key_passphrase} eq '_OB_KEYCHAIN_')) {
					my $cache_id = join('|', 'key', $project->{prefs}->{rsync_username}, $project->{prefs}->{rsync_ssh_key_file});
					$project->{prefs}->{rsync_ssh_key_passphrase} = $password_cache->{$cache_id} || 'FAIL';
				}
				
				# set refresh flag only if project was really modified
				if ($project->{prefs}->{mod_date} != $old_mod_date) {
					$project->{refresh} = 1;
				}
			}
		} # parsed prefs
	} # loaded prefs
}

sub is_file_excluded {
	# check if filename is on the excluded and/or included list
	# need to emulate rsync's behavior here -- exclude first, then include (include can override exclude)
	my ($self, $project, $file) = @_;
	my $excluded = 0;
	
	if ($project->{prefs}->{exclude_files}) {
		if (!$project->{exclude_regexp}) {
			my $groups = [ map { $_ =~ s/(\W)/\\$1/g; $_; } split(/\s+/, $project->{prefs}->{exclude_files}) ];
			$project->{exclude_regexp} = '(' . join('|', map { $_ =~ s/\\\*/.+/g; $_; } @$groups) . ')';
		}
		my $regexp = $project->{exclude_regexp};
		if ($file =~ m@$regexp@) { $excluded = 1; }
	}
	
	if ($project->{prefs}->{include_files}) {
		if (!$project->{include_regexp}) {
			my $groups = [ map { $_ =~ s/(\W)/\\$1/g; $_; } split(/\s+/, $project->{prefs}->{include_files}) ];
			$project->{include_regexp} = '(' . join('|', map { $_ =~ s/\\\*/.+/g; $_; } @$groups) . ')';
		}
		my $regexp = $project->{include_regexp};
		if ($file =~ m@$regexp@) { $excluded = 0; }
	}
	
	return $excluded;
}

sub scan_dir {
	# scan directory for folders and files, and recurse for nested
	my ($self, $project, $base_dir, $files) = @_;
	my $prefs = $project->{prefs};
	# $self->log_debug(8, "Adding directory: $base_dir");
	
	$files ||= {};
	
	# add dir itself
	my @stats = stat($base_dir);
	$files->{$base_dir} = { type => 'd', mtime => $stats[9] };
	
	# scan dir contents
	my $dirh = DirHandle->new( $base_dir );
	if ($dirh) {
		while (my $filename = $dirh->read()) {
			if (($filename ne '.') && ($filename ne '..')) {
				my $file = "$base_dir/$filename";
				next if $self->is_file_excluded($project, $file);

				if ((-l $file) && ($prefs->{rsync_symlinks} =~ /(preserve|ignore)/)) {
					if ($prefs->{rsync_symlinks} eq 'preserve') {
						# treat as normal file, but use lstat and set is_link property
						@stats = lstat($file);
						$files->{$file} = { type => 'l', mtime => $stats[9] };
					}
				}
				elsif (-d $file) {
					# subdirectory
					$self->scan_dir( $project, $file, $files );
				}
				elsif (-f $file) {
					# plain file
					@stats = stat($file);
					$files->{$file} = { type =>'f', mtime => $stats[9] };
				} # plain file
			} # not . or ..
		} # foreach file in dir
	} # got dir handle
	
	return $files;
}

sub check_dir {
	# check dir for changes, recurse for nested, and call rsync if needed
	my ($self, $project, $base_dir) = @_;
	my $prefs = $project->{prefs};
	
	my $need_rsync = 0;
	my $files_to_send = [];
	
	# get current files from hash, from this point inward
	my $files = {};
	foreach my $path (keys %{$project->{files}}) {
		if ($path =~ m@^$base_dir@) { $files->{$path} = $project->{files}->{$path}; }
	}
	
	# re-scan local dir to get new list of files / folders from this point inward
	my $new_files = $self->scan_dir( $project, $base_dir );
	
	# look for changed files (omit directories)
	foreach my $path (keys %$files) {
		my $obj = $files->{$path};
		if ($new_files->{$path} && ($obj->{type} ne 'd') && ($obj->{mtime} != $new_files->{$path}->{mtime})) {
			$self->log_debug(8, "Modified file will be synced: $path");
			$project->{files}->{$path} = $new_files->{$path};
			push @$files_to_send, $path;
			$need_rsync = 1;
		}
	}
	
	# look for new files / directories
	foreach my $path (keys %$new_files) {
		if (!$files->{$path}) {
			$self->log_debug(8, "New file will be synced: $path");
			$project->{files}->{$path} = $new_files->{$path};
			if ($new_files->{$path}->{type} ne 'd') { push @$files_to_send, $path; }
			$need_rsync = 1;
		}
	}
	
	# look for deleted files / directories
	foreach my $path (keys %$files) {
		if (!$new_files->{$path}) {
			$self->log_debug(8, "Deleted file will be synced: $path");
			delete $project->{files}->{$path};
			$need_rsync = 1;
		}
	}
	
	# call rsync if needed
	if ($need_rsync) {
		my $num_files = scalar @$files_to_send; # for progress tracking
		
		# copy to clipboard, if enabled and exactly 1 file was changed
		if ($prefs->{clipboard} && ($num_files == 1)) {
			my $clip_file = abs_path( $files_to_send->[0] );
			my $base_project_dir = abs_path( $prefs->{local_base_dir} );
			$clip_file =~ s@^$base_project_dir@@;
			
			my $clip_url = $prefs->{clip_url};
			$clip_url =~ s@/$@@;
			$clip_url .= $clip_file;
			$self->log_debug(8, "Copying URL to clipboard: $clip_url");
			
			my $base_clip_cmd = $self->{config}->{BaseClipCommand};
			`echo "$clip_url" | $base_clip_cmd`;
		}
		
		$self->rsync( $project, $base_dir, $num_files );
		$self->log_debug(6, "Returning to event loop.");
	}
	else {
		$self->log_debug(6, "No rsync needed (false alarm), returning to event loop.");
	}
}

sub setup_filters {
	# setup exclude or include file patterns for project
	# call once at child startup, and when prefs are reloaded
	my ($self, $project) = @_;
	my $prefs = $project->{prefs};
	
	if ($project->{exclude_temp_file}) {
		unlink $project->{exclude_temp_file};
		delete $project->{exclude_temp_file};
	}
	if ($project->{include_temp_file}) {
		unlink $project->{include_temp_file};
		delete $project->{include_temp_file};
	}
	
	if ($prefs->{exclude_files}) {
		my $exclude_raw = $prefs->{exclude_files}; $exclude_raw =~ s/\s+/\n/g;
		my $filter_temp_file = $self->{config}->{TempDir} . '/exclude-temp-'.$$.'.txt';
		save_file( $filter_temp_file, $exclude_raw );
		$project->{exclude_temp_file} = $filter_temp_file;
	}
	if ($prefs->{include_files}) {
		my $include_raw = $prefs->{include_files}; $include_raw =~ s/\s+/\n/g;
		my $filter_temp_file = $self->{config}->{TempDir} . '/include-temp-'.$$.'.txt';
		save_file( $filter_temp_file, $include_raw );
		$project->{include_temp_file} = $filter_temp_file;
	}
}

sub get_rsync_cmd {
	# get formatted rsync command for project, sans source and dest dirs/files
	my ($self, $project, $file, $extras, $downsync) = @_;
	my $prefs = $project->{prefs};
	
	my $username = $prefs->{rsync_username} || $ENV{'USER'};
	my $cmd = $self->{config}->{BaseRsyncCommand};
	$cmd .= ' -e "';
	
	$cmd .= $self->{config}->{BaseSSHCommand} . ' -l '.$username;
	if ($prefs->{rsync_ssh_key_file}) {
		$cmd .= ' -i ' . $prefs->{rsync_ssh_key_file};
	}
	if ($prefs->{rsync_ssh_port}) {
		$cmd .= ' -p ' . $prefs->{rsync_ssh_port};
	}
	$cmd .= ' ' . ($prefs->{ssh_options} || $self->{config}->{SSHOptions});
	
	if ($prefs->{rsync_password}) {
		$cmd .= ' -oPasswordAuthentication=yes -oPubkeyAuthentication=no';
	}
	else {
		$cmd .= ' -oPasswordAuthentication=no -oPubkeyAuthentication=yes';
	}
	$cmd .= '"';
	
	$cmd .= ' --progress --stats --out-format="SENT:%i /%f"';
	
	if ($prefs->{rsync_symlinks}) {
		if ($prefs->{rsync_symlinks} =~ /preserve/) { $cmd .= ' --links'; }
		elsif ($prefs->{rsync_symlinks} =~ /follow/) { $cmd .= ' --copy-links'; }
		elsif ($prefs->{rsync_symlinks} =~ /ignore/) { ; }
	}
	
	if ($prefs->{rsync_update}) { $cmd .= ' --update'; }
	if ($prefs->{rsync_compress}) { $cmd .= ' --compress'; }
	if ($prefs->{rsync_delete}) { $cmd .= ' --delete'; }
	if ($prefs->{rsync_timeout}) { $cmd .= ' --timeout=' . $prefs->{rsync_timeout}; }
	if ($prefs->{rsync_kbrate}) { $cmd .= ' --bwlimit=' . $prefs->{rsync_kbrate}; }
	if ($prefs->{rsync_backup}) {
		my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = localtime( time() );
		$cmd .= ' --backup --suffix="'.sprintf( ".%0004d-%02d-%02d-%02d-%02d-%02d", $year + 1900, $mon + 1, $mday, $hour, $min, $sec ).'"'; 
	}
	if ($prefs->{rsync_users_groups}) {
		$cmd .= ' --owner --group';
	}
	
	if ($project->{include_temp_file}) {
		$cmd .= ' --include-from=' . $project->{include_temp_file};
	}
	if ($project->{exclude_temp_file}) {
		$cmd .= ' --exclude-from=' . $project->{exclude_temp_file};
	}
	
	# extras
	if ($extras) { $cmd .= ' ' . $extras; }
	
	# local file
	my $temp_path = $file;
	if ((-d $temp_path) && !( (-l $temp_path) && ($prefs->{rsync_symlinks} eq 'preserve') )) {
		# rsync likes trailing slashes for dirs (but not symlinks to dirs in preserve mode!)
		$temp_path .= '/';
	}
	# $cmd .= ' "' . $temp_path . '"';
	my $local_file_cmd = ' "' . $temp_path . '"';
	
	# remote file
	my $local_base_dir = $prefs->{local_base_dir};
	my $remote_base_dir = $prefs->{remote_base_dir};
	my $remote_file = $temp_path; $remote_file =~ s@^$local_base_dir@$remote_base_dir@;
	# $cmd .= ' "' . $prefs->{remote_hostname} . ':' . $remote_file . '"';
	my $remote_file_cmd = ' "' . $prefs->{remote_hostname} . ':' . $remote_file . '"';
	
	# support upsync or downsync
	if (!$downsync) {
		$cmd .= $local_file_cmd . $remote_file_cmd;
	}
	else {
		$cmd .= $remote_file_cmd . $local_file_cmd;
	}
	
	return $cmd;
}

sub rsync_dry_count {
	# perform rsync dry run, just to get file count
	my ($self, $project, $file, $downsync) = @_;
	my $prefs = $project->{prefs};
	my $num_files = 0;
	my $need_rsync = 0;
	$downsync ||= 0;
	my $direction = $downsync ? 'downsync' : 'upsync';
	
	my $cmd = $self->get_rsync_cmd( $project, $file, '--dry-run', $downsync );
	$self->log_debug(9, "Executing rsync dry run for $direction: $cmd");
	
	$self->update_project_status( $project, {
		code => 0,
		progress => -1,
		description => "Analyzing files..."
	});
	
	delete $ENV{'SSH_AUTH_SOCK'};
	
	my $pty = IO::Pty::Easy->new;
	$pty->spawn($cmd . ' 2>&1');
	my $sent_pass = 0;
	my $result = '';
	my $last_ch_seen = time();
	
	while ($pty->is_active) {
		my $buffer = $pty->read(1, 256);
		$buffer =~ s/\r\n/\n/sg;
		$buffer =~ s/\r/\n/sg;
		
		if ($prefs->{rsync_password} && !$sent_pass && ($buffer =~ /\bpassword\:/)) {
			$self->log_debug(9, "We were prompted for a password, sending it now.");
			$pty->write( $prefs->{rsync_password} . "\n", 0 );
			$sent_pass = 1;
		}
		elsif ($prefs->{rsync_ssh_key_passphrase} && ($prefs->{rsync_ssh_key_passphrase} ne '_OB_NOPASS_') && !$sent_pass && ($buffer =~ /\bpassphrase\b/)) {
			$self->log_debug(9, "We were prompted for an ssh private key passphrase, sending it now.");
			$pty->write( $prefs->{rsync_ssh_key_passphrase} . "\n", 0 );
			$sent_pass = 1;
		}
				
		if ($buffer =~ /\S/) {
			$last_ch_seen = time();
			foreach my $line (split(/\n/, $buffer)) {
				chomp $line; $line =~ s/^\s+//; $line =~ s/\s+$//;
				$result .= "$line\n";
			} # foreach line
		}
		
		if ($self->{daemon}->{sig_term}) {
			$self->log_debug(3, "Caught SIGTERM, aborting rsync dry run in progress.");
			$self->update_project_status( $project, { code => 0, description => "Sync aborted due to shutdown signal." });
			$pty->close();
			return (0, 0);
		}
		if ((time() - $last_ch_seen) >= $self->{config}->{IdleTimeout}) {
			$self->log_debug(3, "Idle timeout, aborting rsync dry run in progress.");
			$self->update_project_status( $project, { code => 0, description => "Sync aborted due to timeout error." });
			$pty->close();
			return (0, 0);
		}
	} # while pty is active
	
	$self->log_debug(9, ucfirst($direction) . " dry run complete");
		
	my $rsync_errors = [];
	
	foreach my $line (split(/\n/, $result)) {
		chomp $line; $line =~ s/^\s+//; $line =~ s/\s+$//;
		if ($line =~ /^SENT\:(\S+)\s+(.+)$/) {
			my $rcode = $1;
			my $rtype = substr($rcode, 1, 1);
			my $path = canonpath($2); # normalize . and ..
			if (($rtype eq 'f') && ($rcode =~ /^(\<|\>)/)) { $num_files++; }
			$need_rsync = 1;
		}
		elsif ($line =~ /^(rsync|error|ssh|permission)/i) {
			push @$rsync_errors, $line;
		}
	}
	
	if (@$rsync_errors) {
		# errors occurred!
		my $error_msg = join(", ", @$rsync_errors);
		$project->{last_error} = $error_msg;
		$self->log_debug(2, "Error from rsync: $error_msg");
		$self->update_project_status( $project, {
			code => 1,
			description => "Error from rsync: " . join("\n", @$rsync_errors)
		});
		
		if ($project->{last_rsync_result} ne 'error') {
			# growl error, but only once until we get a success
			my $msg = "Error: Could not sync files.  See the application window for details.";
			$self->growl( $project, $self->{config}->{ErrorIcon}, $msg );
			$self->play_sound( $project, 'error' );
		}
		
		$project->{last_rsync_result} = 'error';
		return (0, 0);
	}
	else {
		$self->log_debug(9, "According to rsync dry run, $num_files files will be synced" . 
			((!$num_files && $need_rsync) ? ', but other actions are required' : ''));
		
		$self->update_project_status( $project, {
			code => 0,
			description => "Analyze complete, $num_files files will be synced."
		});
		
		return ($need_rsync, $num_files);
	}
}

sub rsync {
	# rsync single file or directory to remote server
	my ($self, $project, $file, $num_files, $downsync) = @_;
	my $prefs = $project->{prefs};
	$downsync ||= 0;
	my $direction = $downsync ? 'downsync' : 'upsync';
	
	my $cmd = $self->get_rsync_cmd( $project, $file, '', $downsync );
	
	$self->update_project_status( $project, {
		code => 0,
		progress => -1,
		description => "Synchronizing files..."
	});
	
	if ($prefs->{growl} && $prefs->{growl_sync_start}) {
		$self->growl( $project, $downsync ? $self->{config}->{DownloadIcon} : $self->{config}->{UploadIcon}, "Synchronizing files..." );
	}
	if ($num_files) { $self->play_sound( $project, 'sync_start' ); }
	
	my $rsync_log_file = $ENV{'HOME'} . '/Library/Logs/OpenBox-rsync.log.txt';
	my $rsync_log_fh = FileHandle->new(">>$rsync_log_file");
	if ($rsync_log_fh) {
		$rsync_log_fh->autoflush();
		my $nice_date_time = scalar localtime;
		my $ptitle = $prefs->{title} || '';
		my $proj_id = $project->{id};
		$rsync_log_fh->print("\n---- Begin $direction session at $nice_date_time for project $ptitle ($proj_id) ----\n\n$cmd\n\n");
	}
	
	$self->log_debug(9, "Opening rsync pipe for $direction: $cmd");
	
	my $files_sent = [];
	my $files_deleted = [];
	my $dirs_sent = [];
	my $things_sent = [];
	my $num_sent = 0;
	my $num_complete = 0;
	my $partial_pct = 0;
	my $rstats = {};
	my $rsync_errors = [];
	my $last_progress_update = time();
	my $time_start = time();
	my $last_ch_seen = time();
	my $last_line_100pct = 0;
	
	# local $/ = "\r";
	delete $ENV{'SSH_AUTH_SOCK'};
	
	my $pty = IO::Pty::Easy->new;
	$pty->spawn($cmd . ' 2>&1');
	my $sent_pass = 0;
	
	while ($pty->is_active) {
		my $buffer = $pty->read(1, 256);
		$buffer =~ s/\r\n/\n/sg;
		$buffer =~ s/\r/\n/sg;
		
		if ($prefs->{rsync_password} && !$sent_pass && ($buffer =~ /\bpassword\:/)) {
			$self->log_debug(9, "We were prompted for a password, sending it now.");
			$pty->write( $prefs->{rsync_password} . "\n", 0 );
			$sent_pass = 1;
		}
		elsif ($prefs->{rsync_ssh_key_passphrase} && ($prefs->{rsync_ssh_key_passphrase} ne '_OB_NOPASS_') && !$sent_pass && ($buffer =~ /\bpassphrase\b/)) {
			$self->log_debug(9, "We were prompted for an ssh private key passphrase, sending it now.");
			$pty->write( $prefs->{rsync_ssh_key_passphrase} . "\n", 0 );
			$sent_pass = 1;
		}
		
		if ($buffer =~ /\S/) {
			$last_ch_seen = time();
			foreach my $line (split(/\n/, $buffer)) {
				chomp $line; $line =~ s/^\s+//; $line =~ s/\s+$//;
				if ($rsync_log_fh) { $rsync_log_fh->print("$line\n"); }
				$last_line_100pct = 0;
		
				# SENT:<f+++++++ /gamerebirth/work/datadrain/data_drain_2.psd
				if ($line =~ /^SENT\:(\S+)\s+(.+)$/) {
					my $rcode = $1;
					my $rtype = substr($rcode, 1, 1);
					my $path = canonpath($2); # normalize . and ..
			
					if ($rcode =~ /\*delet/) {
						# deleted file (or directory, very difficult to tell)
						push @$files_deleted, $path;
						push @$things_sent, $path;
						$num_sent++;
					}
					elsif (($rtype eq 'L') && ($prefs->{rsync_symlinks} =~ /(preserve|ignore)/)) {
						if ($prefs->{rsync_symlinks} eq 'preserve') {
							push @$files_sent, $path;
							push @$things_sent, $path;
							$num_sent++;
						}
					}
					elsif (($rtype eq 'f') && ($rcode =~ /^(\<|\>)/)) {
						push @$files_sent, $path;
						push @$things_sent, $path;
						$num_sent++;
					} # file sent
					elsif (($rtype eq 'd') && ($rcode =~ /^cd/)) {
						# directory created
						push @$dirs_sent, $path;
						push @$things_sent, $path;
						$num_sent++;
					} # dir sent
				} # line contains 'SENT:'
		
				#  2829708 100%  579.67kB/s    0:00:04 (xfer#1, to-check=5/7)
			    elsif ($line =~ /^(\d+)\s+100\%.+to\-check\=\d+\/\d+/) {
					# file complete
					my $file_bytes = $1;
					my $stat_key = $downsync ? 'bytes_received' : 'bytes_sent';
					$rstats->{$stat_key} += int($file_bytes);
			
					my $fstat_key = $downsync ? 'files_received' : 'files_sent';
					$rstats->{$fstat_key}++;
			
					my $pstat_key = $downsync ? 'partial_received' : 'partial_sent';
					delete $rstats->{$pstat_key};
			
					$num_complete++;
					$partial_pct = 0;
					
					$last_line_100pct = 1;
				}
		
				# 2228224  78%    1.44MB/s    0:00:00
		     	elsif ($line =~ /^(\d+)\s+(\d+)\%\s+\d+/) {
					# progress inside file
					my $partial_bytes = $1;
					$partial_pct = $2;
					my $pstat_key = $downsync ? 'partial_received' : 'partial_sent';
					$rstats->{$pstat_key} = int($partial_bytes);
				}
		
				# rsync: connection unexpectedly closed (0 bytes received so far) [sender]
				elsif ($line =~ /^(rsync|error|ssh|permission)/i) {
					push @$rsync_errors, $line;
				}
			} # foreach rsync output line
		} # buffer contains non-whitespace
		
		my $progress = -1;
		if ($num_files) {
			$progress = (($num_complete + ($partial_pct / 100)) / $num_files);
		}
		if ($progress > 1.0) { $progress = 1.0; }
		# $self->log_debug(9, "Progress: $progress");
	
		# update progress often
		my $now = time();
		if (($now - $last_progress_update) >= $self->{config}->{ProgressUpdateInterval}) {
			$last_progress_update = $now;
			my $msg = "Synchronizing files...";
			if ($num_files) { $msg = "Synchronizing $num_files file".(($num_files != 1) ? 's' : '')."..."; }
			$self->update_project_status( $project, {
				code => 0,
				progress => $progress,
				time_start => $time_start,
				time_now => $now,
				description => $msg,
				stats => $rstats
			});
			$self->log_debug(9, "Current overall rsync progress: $progress / 1.0");
		}
	
		if ($self->{daemon}->{sig_term}) {
			$self->log_debug(3, "Caught SIGTERM, aborting rsync in progress.");
			my $nice_date_time = scalar localtime;
			if ($rsync_log_fh) { $rsync_log_fh->print("\n\nCAUGHT SIGTERM at $nice_date_time -- ABORTING OPERATION IN PROGRESS!\n\n"); }
			$self->update_project_status( $project, { code => 0, description => "Sync aborted due to shutdown signal." });
			$pty->close();
			return 0;
		}
		
		my $timeout_secs = $self->{config}->{IdleTimeout};
		if ($last_line_100pct) { $timeout_secs *= 10; } # rsync likes to hang at 100%, so give it LOTS of extra time
		if ((time() - $last_ch_seen) >= $timeout_secs) {
			$self->log_debug(3, "Idle timeout, aborting rsync in progress.");
			my $nice_date_time = scalar localtime;
			if ($rsync_log_fh) { $rsync_log_fh->print("\n\nTIMEOUT ERROR at $nice_date_time -- ABORTING OPERATION IN PROGRESS!\n\n"); }
			$self->update_project_status( $project, { code => 1, description => "Sync aborted due to timeout error." });
			$pty->close();
			return 0;
		}
	} # while pty is active
	
	$self->log_debug(6, ucfirst($direction) . " operation complete");
	$self->update_project_status( $project, { code => 0, description => "Sync complete." });
		
	if ($rstats->{bytes_sent} || $rstats->{bytes_received} || $rstats->{files_sent} || $rstats->{files_received}) {
		delete $rstats->{partial_received};
		delete $rstats->{partial_sent};
		
		my $elapsed = time() - $time_start;
		my $tstat_key = $downsync ? 'downsync_elapsed' : 'upsync_elapsed';
		$rstats->{$tstat_key} = $elapsed;
		
		$self->update_global_stats( $rstats );
	}
	
	if (@$rsync_errors) {
		# errors occurred!
		my $error_msg = join(", ", @$rsync_errors);
		$project->{last_error} = $error_msg;
		$self->log_debug(2, "Error from rsync: $error_msg");
		
		$self->update_project_status( $project, {
			code => 1,
			description => "Error from rsync: " . join("\n", @$rsync_errors)
		});
		
		if ($project->{last_rsync_result} ne 'error') {
			# growl error, but only once until we get a success
			my $msg = "Error: Could not sync files.  See the application window for details.";
			$self->growl( $project, $self->{config}->{ErrorIcon}, $msg );
			$self->play_sound( $project, 'error' );
		}
		
		$project->{last_rsync_result} = 'error';
		
		# if this was an upsync attempt, set flags so we keep trying periodically
		if (!$downsync) {
			$self->log_debug(4, "Setting error flag for periodic upsync retry");
			$project->{last_upsync_retry} = time();
		}
	}
	elsif ($num_sent) {
		# success, no errors
		my $msg = '';
		if ($num_sent == 1) {
			my $action = 'synced';
			my $kind = 'File';
			my $path = shift @$files_sent;
			if (!$path) {
				$path = shift @$dirs_sent;
				$kind = 'Folder';
				if (!$path) {
					$path = shift @$files_deleted;
					$kind = 'File';
					$action = 'deleted';
				}
			}
			my $filename = basename($path); $filename =~ s/[^\w\s\-\.\/]+//g;
			$msg = $kind . " \"" . $filename . "\" was $action";
		}
		else {
			$msg = $num_sent . " files were synced";
		}
		$msg .= ".";
		
		if ($prefs->{growl} && $prefs->{growl_sync_end}) {
			$self->growl( $project, $downsync ? $self->{config}->{DownloadIcon} : $self->{config}->{UploadIcon}, $msg );
		}
		$self->play_sound( $project, 'sync_end' );
		
		$self->update_project_status( $project, {
			code => 0,
			description => $msg
			# description => "Successfully synced files: \n" . join("\n", @$things_sent)
		});
		
		$project->{last_rsync_result} = 'success';
	}
	else {
		# success, no files
		$project->{last_rsync_result} = 'success';
		
		if ($prefs->{growl} && $prefs->{growl_sync_start} && $prefs->{growl_sync_end}) {
			$self->growl( $project, $downsync ? $self->{config}->{DownloadIcon} : $self->{config}->{UploadIcon}, "No files were modified." );
		}
		# $self->play_sound( $project, 'sync_end' );
	}
	
	return $num_sent;
}

sub growl {
	# send command to growlnotify or cocoadialog
	my ($self, $project, $img_filename, $msg) = @_;
	my $prefs = $project->{prefs};
	if (!$prefs->{growl}) { return; }
	if (($img_filename eq $self->{config}->{ErrorIcon}) && !$prefs->{growl_errors}) { return; }
	
	my $img = abs_path( dirname( getcwd() ) ) . '/Resources/' . $img_filename;
	my $id = 'openbox_' . $project->{id};
	$msg =~ s/\"/\\"/g;
	
	my $title = $prefs->{title} || 'OpenBox'; 
	$title =~ s/[^\w\s\-\.\/]+//g;
	
	my $growl_cmd = '';
	if ($self->{notify_type} =~ /growl/) {
		# growl 1.2 or 1.3
		$growl_cmd = $self->{notify_type} . ' --image "'.$img.'" --identifier "'.$id.'" --message "'.$msg.'" "' . $title . '"';;
	}
	else {
		# no growl, use cocoadialog bubble
		$growl_cmd = $self->{notify_type} . ' bubble --title "'.$title.'" --text "'.$msg.'" --icon-file "'.$img.'" --text-color "ffffff" --border-color "444444" --background-top "000000" --background-bottom "444444" --alpha 0.95 --timeout 5';
	}
	
	$self->log_debug(9, "Growling: $growl_cmd");
	system($growl_cmd . ' >/dev/null 2>&1 &');
}

sub play_sound {
	# play named sound
	my ($self, $project, $event_name) = @_;
	my $prefs = $project->{prefs};
	if (!$prefs->{sound}) { return; }
	if (!$prefs->{'sound_'.$event_name}) { return; }
	
	my $sound_filename = $event_name;
	$sound_filename =~ s/_/-/g;
	$sound_filename .= '.mp3';
	
	my $sound_file = abs_path( dirname( getcwd() ) ) . '/Resources/sounds/' . $sound_filename;
	my $sound_cmd = $self->{config}->{BaseSoundCommand} . ' ' . $sound_file;
	$self->log_debug(9, "Playing Sound: $sound_cmd");
	system($sound_cmd . ' >/dev/null 2>&1 &');
}

sub update_project_status {
	# write out progress json file which app UI polls
	my ($self, $project, $json) = @_;
	$json->{code} ||= 0;
	$json->{date} ||= time();
	save_file_atomic( $project->{status_file}, json_compose($json) );
}

sub update_global_stats {
	# update stats json file which app UI polls
	my ($self, $update) = @_;
	my $stats_file = $self->{config}->{TempDir} . '/global-stats.json';
	my $stats = undef;
	eval { $stats = json_parse( load_file($stats_file) || '{}' ); };
	if (!$stats) { $stats = {}; }
	
	foreach my $key (keys %$update) {
		$stats->{$key} += $update->{$key};
	}
	
	save_file_atomic( $stats_file, json_compose($stats) );
}

sub load_prefs {
	# load prefs from disk, setup monitoring
	# this is only called from the parent daemon, not in any children
	my $self = shift;
	
	$self->{prefs} = {};
	$self->log_debug(3, "Loading prefs: " . $self->{prefs_file});
	
	my $prefs_raw = load_file($self->{prefs_file});
	if ($prefs_raw) {
		my $prefs = undef;
		eval { $prefs = json_parse( $prefs_raw ); };
		if (!$@ && $prefs) {
			$self->{prefs} = $prefs;
		}
	}
	
	$self->{prefs}->{projects} ||= [];
	
	$self->{prefs}->{_ModDate} = (stat($self->{prefs_file}))[9];
	$self->{prefs}->{_CheckTime} = time();
	
	# reattach prefs to existing projects, and load passwords as needed
	foreach my $project (@{$self->{projects}}) {
		# $project->{refresh} = 1;
		$project->{prefs} = find_object( $self->{prefs}->{projects}, { id => $project->{id} } );
		if ($project->{prefs}) {
			$self->preload_project_passwords( $project );
		}
	} # foreach project
	
	# force a check on all projects
	$self->{last_maint_check} = 0;
	
	# if master enable has been turned off, we're outta here
	if (!$self->{prefs}->{daemon_enabled}) {
		$self->log_debug( 2, "Master switch is off, exiting now." );
		$self->{daemon}->{sig_term} = 1;
		
		foreach my $project (@{$self->{projects}}) {
			delete $project->{_send_load_prefs};
		}
	}
}

sub monitor_prefs {
	# monitor prefs file for changes
	# no greater than one check per second
	my $self = shift;
	my $now = time();
	
	if (!$self->{prefs}->{_CheckTime} || (($now - $self->{prefs}->{_CheckTime}) >= $self->{config}->{PrefsFileCheckInterval})) {
		# time to check
		$self->{prefs}->{_CheckTime} = $now;
		my $mod_date = (stat($self->{prefs_file}))[9];
		if ($mod_date != $self->{prefs}->{_ModDate}) {
			# file changed, reload!
			$self->log_debug(4, "Prefs have changed on disk, reloading.");
			$self->load_prefs();
		} # file changed
	} # time to check
}

sub preload_project_passwords {
	# fetch password or passphrase from keychain, if required
	my ($self, $project) = @_;
	my $prefs = $project->{prefs};
	
	# keep track of unique passwords so we only fetch each one once
	$self->{password_cache} ||= {};
	my $password_cache = $self->{password_cache};
	
	if ($prefs->{rsync_password} && ($prefs->{rsync_password} eq '_OB_KEYCHAIN_')) {
		my $cache_id = join('|', 'pass', $prefs->{rsync_username}, $prefs->{remote_hostname});
		
		# check for expired password
		my $need_password_refresh = 0;
		if (unlink($self->{config}->{TempDir} . '/update-password-'.$project->{id}.'.txt')) {
			delete $password_cache->{$cache_id};
			$need_password_refresh = 1;
		}
		
		my $password = $password_cache->{$cache_id} || $self->find_password_in_keychain( 'pass', $prefs->{rsync_username}, $prefs->{remote_hostname} );
		if (!length($password)) {
			$self->log_debug(1, "Failed to fetch password from keychain");
			$self->growl( $project, $self->{config}->{ErrorIcon}, "Failed to fetch password from keychain.  Please verify your settings." );
			$prefs->{enabled} = 0; # prevent child from forking until prefs are reloaded
			$self->play_sound( $project, 'error' );
		}
		else {
			$prefs->{rsync_password} = $password;
			$password_cache->{$cache_id} = $password;
			
			if ($need_password_refresh && $project->{pid}) {
				$self->log_debug(3, "Reloading project child for password change: " . $project->{id} . ": " . $project->{pid});
				kill( 1, $project->{pid} ); # SIGTERM
				delete $project->{pid};
				delete $project->{_send_load_prefs};
			}
		}
	}
	elsif ($prefs->{rsync_ssh_key_passphrase} && ($prefs->{rsync_ssh_key_passphrase} eq '_OB_KEYCHAIN_')) {
		my $cache_id = join('|', 'key', $prefs->{rsync_username}, $prefs->{rsync_ssh_key_file});
		
		# check for expired password
		my $need_password_refresh = 0;
		if (unlink($self->{config}->{TempDir} . '/update-password-'.$project->{id}.'.txt')) {
			delete $password_cache->{$cache_id};
			$need_password_refresh = 1;
		}
		
		my $password = $password_cache->{$cache_id} || $self->find_password_in_keychain( 'key', $prefs->{rsync_username}, $prefs->{rsync_ssh_key_file} );
		if (!length($password)) {
			$self->log_debug(1, "Failed to fetch SSH private key passphrase from keychain");
			$self->growl( $project, $self->{config}->{ErrorIcon}, "Failed to fetch SSH private key passphrase from keychain.  Please verify your settings." );
			$prefs->{enabled} = 0; # prevent child from forking until prefs are reloaded
			$self->play_sound( $project, 'error' );
		}
		else {
			$prefs->{rsync_ssh_key_passphrase} = $password;
			$password_cache->{$cache_id} = $password;
			
			if ($need_password_refresh && $project->{pid}) {
				$self->log_debug(3, "Reloading project child for password change: " . $project->{id} . ": " . $project->{pid});
				kill( 1, $project->{pid} ); # SIGTERM
				delete $project->{pid};
				delete $project->{_send_load_prefs};
			}
		}
	}
}

sub yyyy_mm_dd_hh_mi_ss {
	##
	# Return date in YYYY-MM-DD HH:MI:SS format given epoch
	##
	my $epoch = shift;
	
	my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = localtime( $epoch );
	return sprintf( "%0004d-%02d-%02d %02d:%02d:%02d", $year + 1900, $mon + 1, $mday, $hour, $min, $sec );
}

sub log_debug {
	##
	# Log to debug log
	##
	my ($self, $level, $msg) = @_;
	
	if ($level <= $daemon->{debug_level}) {
		$self->log_print(
			log => 'debug',
			component => ($$ == $daemon->{daemon_pid}) ? 'daemon' : 'child',
			code => $level,
			msg => $msg
		);
	}
}

sub log_print {
	##
	# Print to log file
	##
	my $self = shift;
	my $args = {@_};
	
	my $fh = FileHandle->new( '>>' . $ENV{'HOME'} . '/Library/Logs/OpenBox-daemon.log.txt' );
	if ($fh) {
		my $now = time();
		$fh->print( '[' . join('][', 
			$now,
			yyyy_mm_dd_hh_mi_ss($now),
			'OpenBox',
			$$,
			$args->{component},
			$args->{code},
			$args->{msg}
		) . "]\n");
	}
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
