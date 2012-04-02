#!/usr/bin/perl

package OpenBoxUI;

##
# AppStr App Framework
# Preforking HTTP Server for UI and launch requests
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
use UNIVERSAL qw/isa/;
use Cwd qw/getcwd abs_path/;

chdir dirname($0);
require 'JSON.pm';
require 'Daemon.pm';
require 'utils.pl';
require 'api.pl';
eval 'use IO::Pty::Easy;';

$| = 1;

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
		die "Failed to create temporary directory: " . $resident->{config}->{TempDir} . ": $!\n";
	}
}

my $info_plist = load_file( '../Info.plist' );
my $bundle_name = 'OpenBox UI';
# if ($info_plist =~ m@<key>CFBundleName</key>\s+<string>(.+?)</string>@) { $bundle_name = $1; }
my $process_name = $bundle_name; $process_name =~ s/\W+//g;

$resident->{bundle_name} = $bundle_name;
$resident->{process_name} = $process_name;

my $bundle_id = 'com.unknown.app';
if ($info_plist =~ m@<key>CFBundleIdentifier</key>\s+<string>(.+?)</string>@) { $bundle_id = $1; }
$resident->{bundle_id} = $bundle_id;

##
# Setup preforking HTTP server
##
my $daemon = $resident->{daemon} = Daemon->new(
	name => $bundle_name,
	process_name => $process_name,
	pid_file => $resident->{config}->{TempDir} . "/$bundle_id.pid",
	# stop_file => "/var/tmp/$bundle_id.stop",
	debug_level => $resident->{config}->{UIDebugLevel},
	no_fork => 1,
	logger => $resident,
	growl => '',
	port => 0, # will pick random available local port
	max_children => $resident->{config}->{MaxUIChildren},
	max_requests_per_child => 0,
	ttl => $resident->{config}->{TTL},
	file_types => $resident->{config}->{FileTypes},
	request_handler => \&handle_request,
	cleanup_handler => \&cleanup,
	idle_handler => \&idle,
	idle_time => 1.0
);

# Ctrl-C handler, so we exit gracefully
$SIG{INT} = sub { $daemon->{sig_term} = 1; };

# Make sure stop file is deleted (API can create it for us to exit).
# unlink $daemon->{stop_file};

# start daemon (fork children)
$daemon->startup();

# load prefs
$resident->{prefs_file} = $ENV{'HOME'} . '/Library/Preferences/' . $resident->{bundle_id} . '.json';
$resident->{first_prefs_load} = 1;
$resident->load_prefs();

# go into idle loop
$daemon->idle();

# In case user quickly flipped master enable switch then exited, check prefs here
$resident->{prefs}->{_CheckTime} = 0;
$resident->monitor_prefs();

# Delete temp js file used by UI
unlink( '../Resources/server.js' );

exit;

sub handle_request {
	my ($daemon, $request, $socket) = @_;
	
	my $self = $resident;
	$self->{request} = $request;
	$self->{socket} = $socket;
	
	my $uri = $request->url();
	if ($uri =~ m@^/api/(\w+)@) {
		# api call
		my $cmd = $1;
		my $query = $self->{query} = parse_query($uri);
		return $self->handle_api($cmd, $query, $daemon, $request, $socket);
	}
	
	if ($uri =~ /favicon.ico/) {
		return $daemon->send_response( 404, "File Not Found", "File Not Found: $uri" );
	}
	
	# static file or directory...
	
	my $raw_query = '';
	if ($uri =~ /\?(.+)$/) { $raw_query = '?' . $1; }
	
	$uri =~ s/\?.*$//; # strip query
	# if (!length($uri)) { $uri = '/'; }
	
	my $file = '../Resources' . $uri;
	if (-d $file) {
		if ($file =~ /\/$/) { $file .= 'index.html'; }
		else {
			return $daemon->send_redirect( 301, $uri . '/' . $raw_query );
		}
	}
	
	if (-e $file) {
		return $daemon->send_file( $file );
	}
	
	return $daemon->send_response( 404, "File Not Found", "File Not Found: $file" );
}

sub handle_api {
	##
	# Handle API call with JSON response
	##
	my ($self, $cmd, $query, $daemon, $request, $socket) = @_;
	my $func = 'api_' . $cmd;
	my $resp = undef;
	$self->{output_sent} = 0;
	
	my $json = {};
	my $content = $request->content();
	if ($content) {
		# $self->log_debug(9, "Incoming POST data: $content"); # warning: log may contain plaintext passwords
		eval { $json = json_parse($content); };
		if ($@) {
			$resp = { Code => 1, Description => "Failed to parse JSON: $cmd: $@" };
		}
	}
	
	# merge query into json
	foreach my $key (keys %$query) { $json->{$key} = $query->{$key}; }
	
	if (!$resp) {
		if ($self->can($func)) {
			$self->log_debug(9, "Invoking API handler: $func");
			eval { $resp = $self->$func( $json, $daemon, $request, $socket ); };
			if ($self->{output_sent}) { return 1; }
			if ($@) {
				$resp = { Code => 1, Description => "API Crashed: $cmd: $@" };
			}
		}
		else {
			$resp = { Code => 1, Description => "No API handler defined for: $cmd" };
		}
	} # no error
	
	# use applescript to display error
	if ($resp->{Code} && $json->{auto_error}) {
		my $esc_msg = $resp->{Description};
		$esc_msg =~ s/\n/\\n/g; $esc_msg =~ s/\"/\\"/g;
		$self->call_applescript( join("\n",
			'tell application "OpenBox"',
				'activate',
				'display alert "Sorry, an OpenBox error occurred:" message "'.$esc_msg.'" as warning',
			'end tell'
		) );
	}
	
	my $content_type = 'text/javascript';
	my $content = '';
	
	my $headers = $resp->{Headers} || {};
	delete $resp->{Headers};
	
	$content = json_compose($resp);
	if ($query->{callback}) { $content = $query->{callback} . '(' . $content . ');'; }
	
	# $self->log_debug(9, "Sending $content_type Response: $content" ); # warning: log may contain plaintext passwords
	
	my $response = HTTP::Response->new( 200 );
	
	$response->content( $content );
	$response->header("Content-Type" => $content_type);
	
	foreach my $key (keys %$headers) {
		$response->header($key => $headers->{$key});
	}
	
	$self->{socket}->send_response($response);
	$self->{socket}->close();
		
	return 1;
}

sub idle {
	##
	# Called in daemon proc every 1 second
	# We use this only to launch the Appify UI thread
	##
	my $daemon = shift;
	my $self = $resident;
	
	if (!$self->{launched_ui}) {
		# spawn child to exec UI
		$self->{launched_ui} = 1;
		
		my $url = "http://localhost:" . $daemon->{port} . "/";
		
		my $ssh_key_dir = $ENV{'HOME'} . '/.ssh';
		if (!(-d $ssh_key_dir)) { $ssh_key_dir = $ENV{'HOME'}; }
		
		# save API URL and config json in js file for UI to fetch on load
		my $contents = '';
		$contents .= 'var username = "'.$ENV{'USER'}.'";' . "\n";
		$contents .= 'var home_dir = "'.$ENV{'HOME'}.'";' . "\n";
		$contents .= 'var ssh_key_dir = "'.$ssh_key_dir.'";' . "\n";
		$contents .= 'var api_url = "'.$url.'";' . "\n";
		$contents .= 'var prefs = ' . $self->{prefs_raw} . ";\n";
		
		my $plist_file = $ENV{'HOME'} . '/Library/LaunchAgents/' . $self->{config}->{LaunchAgentConfigFilename};
		my $plist_exists = (-e $plist_file) ? 1 : 0;
		$contents .= "var start_on_login = $plist_exists;\n";
		
		if (!save_file( '../Resources/server.js', $contents )) {
			# Cannot write files to our Resources folder, try to regain access via AppleScript
			my $osascript = $self->{config}->{TempDir} . '/OpenBox-Setup';
			if (!(-e $osascript)) { `cp /usr/bin/osascript $osascript`; } # customize app name in dialog
			
			my $res_dir = abs_path( dirname( getcwd() ) ) . '/Resources';
			my $result = `$osascript -e 'do shell script "chmod -R 777 $res_dir" with administrator privileges' 2>&1`;
			
			if (!save_file( '../Resources/server.js', $contents )) {
				my $msg = "Cannot write files to our Resources folder.";
				my $dir = getcwd();
				if ($dir !~ m@/Applications/@) { $msg .= " Please install OpenBox to your Applications folder and try again."; }
				else { $msg .= " Please reinstall OpenBox and try again."; }
			
				$self->call_applescript( join("\n",
					'tell application "System Events"', # telling system events so our app can exit
						'activate',
						'display alert "Sorry, OpenBox cannot launch:" message "'.$msg.'" as warning',
					'end tell'
				) );
				$daemon->log_debug(1, "Fatal error, signaling shutdown sequence");
				$daemon->{sig_term} = 1;
				return;
			} # 2nd try failed
		} # 1st try failed
		
		$self->log_debug(2, "Forking UI child now");		
		my $pid = $daemon->spawn_custom( sub {
			my $daemon = shift;
			my $cmd = './OpenBox';
			$daemon->log_debug(2, "Launching UI: $cmd");
			exec($cmd);
			exit();
		} );
	
		# listen for child exit (this is our queue to exit as well)
		$daemon->add_child_exit_listener( $pid, sub {
			my $daemon = shift;
			$daemon->log_debug(2, "Caught UI child exit, signaling shutdown sequence");
			$daemon->{sig_term} = 1;
		} );
		
		# copy 'security' binary, so we can look good in keychain access
		my $sec_trick = $self->{config}->{TempDir} . '/OpenBox';
		if (!(-e $sec_trick)) {
			`cp /usr/bin/security $sec_trick`;
		}
	} # need to launch ui
	
	# Make sure PID file is recently touched, otherwise we're stale and should quit
	# my $pid_mod = (stat($daemon->{pid_file}))[9];
	# if ((time() - $pid_mod) > 60) {
	#	$self->log_debug(2, "PID file is stale, shutting down now!");
	#	$daemon->{sig_term} = 1;
	# }
	
	# Check for STOP file
	# if (-e $daemon->{stop_file}) {
	#	$self->log_debug(2, "Found STOP file, shutting down now!");
	#	$daemon->{sig_term} = 1;
	#	unlink $daemon->{stop_file};
	# }
	
	# monitor prefs, reload if necessary
	$self->monitor_prefs();
}

sub load_prefs {
	# load prefs from disk, setup monitoring
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
	
	$self->{prefs_raw} = $prefs_raw || '{}';
	$self->{prefs_raw} =~ s/^\s+//;
	$self->{prefs_raw} =~ s/\s+$//;
	
	$self->{prefs}->{_ModDate} = (stat($self->{prefs_file}))[9];
	$self->{prefs}->{_CheckTime} = time();
	
# return;
	
	# sync master enable switch with openboxsyncd daemon state
	my $daemon_pid = $self->is_openboxsyncd_running();
	if ($self->{prefs}->{daemon_enabled} && !$daemon_pid) {
		# need to start daemon
		$self->log_debug(2, "Master switch is on, starting sync daemon");
		system('./openboxsyncd.pl >/dev/null 2>&1 &');
		# system('./test.pl >/dev/null 2>&1 &');
	}
	elsif (!$self->{prefs}->{daemon_enabled} && $daemon_pid) {
		# need to stop daemon
		$self->log_debug(2, "Master switch is off, killing daemon now (PID $daemon_pid)");
		# kill(1, $daemon_pid);
		# my $fh = FileHandle->new( ">" . $self->{config}->{TempDir} . "/openboxsyncd.stop" );
		my $cmd_file = $self->{config}->{TempDir} . "/user-command-$daemon_pid.json";
		if (save_file_atomic( $cmd_file, json_compose({ cmd => 'shutdown' }) )) {
			# send USR1 signal to daemon, so it loads command file
			kill "USR1", $daemon_pid;
		}
		else {
			$self->log_debug(1, "ERROR: Could not write daemon command file: $cmd_file: $!");
		}
	}
	elsif ($daemon_pid && !$self->{first_prefs_load}) {
		# send message to active daemon to reload prefs
		$self->log_debug(2, "Sending signal to daemon to reload prefs");
		my $cmd_file = $self->{config}->{TempDir} . "/user-command-$daemon_pid.json";
		if (save_file_atomic( $cmd_file, json_compose({ cmd => 'load_prefs' }) )) {
			# send USR1 signal to daemon, so it loads command file
			kill "USR1", $daemon_pid;
		}
		else {
			$self->log_debug(1, "ERROR: Could not write daemon command file: $cmd_file: $!");
		}
	}
	
	delete $self->{first_prefs_load};
}

sub is_openboxsyncd_running {
	# determine if openboxsyncd daemon is running, or not
	my $self = shift;
	my $pid_file = $self->{config}->{TempDir} . "/openboxsyncd.pid";
	my $pid = load_file( $pid_file );
	chomp $pid;
	if (!$pid) { return 0; }
	return kill(0, $pid) ? $pid : 0;
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

sub cleanup {
	##
	# Cleanup handler, called after every request
	##
	my ($daemon, $request, $socket) = @_;
		
	delete $resident->{session};
	delete $resident->{socket};
	delete $resident->{request};
	delete $resident->{query};
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
	
	# all rows show up in Mac OS X "Console.app"
	my $fh = $self->{args}->{debug} ? *STDERR : FileHandle->new("|/usr/bin/logger");
	if ($fh) {
		$fh->print( '[' . join('][', 
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
