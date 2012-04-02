##
# AppStr Perl/PHP Framework
# Perl API Handler
# Copyright (c) 2012 Joseph Huckaby
# Released under the MIT License.
##

# Define your API Calls here using: sub api_SOMETHING {}...
# Arguments will be:
#	$self - a reference to an object containing:
#		$self->{config} - a reference to the config.json file, parsed as a hash tree
#		$self->log_debug(LEVEL, MSG) - a function to log to the Mac OS X Console.app
# 	$json - A hash reference to the JSON post data (also contains query string params merged in)
#	$daemon - A reference to the Daemon object (see Daemon.pm)
#	$request - A reference to the HTTP::Request object from HTTP::Daemon 
#	$socket - A refernece to the IO::Socket object from HTTP::Daemon
# Return a hashref containing key/values which will be sent back to your app

use Cwd;
use IO::Socket::INET;

sub api_dialog {
	# invoke CocoaDialog with arbitrary params and return result
	my ($self, $json, $daemon, $request, $socket) = @_;
	
	my $runmode = $json->{mode};
	delete $json->{mode};
	
	my $result = $self->call_dialog( $runmode, $json );
	
	return { Code => 0, Description => "Success", Result => $result };
}

sub api_sound {
	# play sound effect
	my ($self, $json, $daemon, $request, $socket) = @_;
	
	my $sound_file = abs_path( dirname( getcwd() ) ) . '/Resources/sounds/' . $json->{filename};
	my $sound_cmd = $self->{config}->{BaseSoundCommand} . ' ' . $sound_file;
	$self->log_debug(9, "Playing Sound: $sound_cmd");
	system($sound_cmd . ' >/dev/null 2>&1 &');
	
	return { Code => 0, Description => "Success" };
}

sub api_force_sync {
	# send command to running daemon to force a project sync
	my ($self, $json, $daemon, $request, $socket) = @_;
	my $project_id = $json->{project_id};
	
	# first, make sure project isn't in the middle of something
	my $project_status_file = $self->{config}->{TempDir} . '/project-status-' . $project_id . '.json';
	my $project_status = undef;
	eval { $project_status = json_parse( load_file($project_status_file) || '{}' ); };
	if (!$project_status) { $project_status = {}; }
	if ($project_status->{progress}) {
		return { Code => 1, Description => "The box is currenty busy, and cannot be synchroized.  Please check the Status tab for details." };
	}
	
	my $temp_dir = $ENV{'HOME'} . '/.openbox';
	if (!(-d $temp_dir)) {
		return { Code => 1, Description => "Temporary directory does not exist: $temp_dir" };
	}
	
	# setup command
	my $args = {
		cmd => 'project_delegate',
		project_id => $project_id,
		project_cmd => 'sync',
		growl => 1
	};

	# load daemon's PID file
	my $daemon_pid = load_file( $temp_dir . '/openboxsyncd.pid' ) || '';
	chomp $daemon_pid;
	if (!$daemon_pid || !kill(0, $daemon_pid)) {
		return { Code => 1, Description => "OpenBox service is not running, cannot send command." };
	}

	# write command to PID-specific json file
	my $cmd_file = $temp_dir . "/user-command-$daemon_pid.json";
	if (!save_file_atomic( $cmd_file, json_compose( { %$args } ) )) {
		return { Code => 1, Description => "Could not write command file to disk: $cmd_file: $!" };
	}

	# send USR1 signal to daemon, so it loads command file
	kill "USR1", $daemon_pid;
	
	return { Code => 0, Description => "Success" };
}

sub api_export_settings {
	# export settings to file on disk
	my ($self, $json, $daemon, $request, $socket) = @_;
	
	# ask user where to save file
	my $result = $self->call_dialog( 'filesave', {
		'title' => "Export OpenBox Settings",
		'with-extensions' => 'json',
		'with-directory' => $ENV{'HOME'},
		'with-file' => "OpenBox-Settings.json"
	} );
	
	if ($result !~ /\S/) {
		return { Code => 0, Description => "User did not enter a filename." };
	}
	
	$self->log_debug(5, "Exporting settings to file: $result");
	
	if (!save_file( $result, load_file($self->{prefs_file}) )) {
		return { Code => 1, Description => "Failed to save settings file: $!" };
	}
	
	# reveal new file in the finder
	$self->call_applescript( join("\n", 
		'tell application "Finder"',
		'activate',
		'reveal (POSIX file "'.$result.'") as string',
		'end tell'
	) );
	
	return { Code => 0, Description => "Success" };
}

sub api_import_settings {
	# import settings from file on disk
	my ($self, $json, $daemon, $request, $socket) = @_;
	
	# prompt user for file
	my $result = $self->call_dialog( 'fileselect', {
		'title' => "Import OpenBox Settings",
		'text' => "Select an OpenBox settings file to import:",
		'with-extensions' => 'json',
		'with-directory' => $ENV{'HOME'}
	} );
	
	if ($result !~ /\S/) {
		return { Code => 0, Description => "User did not select a file." };
	}
	
	$self->log_debug(5, "Importing settings from file: $result");
	
	# validate new file is proper json
	my $new_prefs_raw = load_file( $result );
	if (!$new_prefs_raw) { 
		return { Code => 1, Description => "Failed to load settings file: $!" }; 
	}
	my $new_prefs = {};
	eval { $new_prefs = json_parse( $new_prefs_raw ); };
	if ($@) { 
		return { Code => 1, Description => "Failed to load settings file: $@" }; 
	}
	if (!$new_prefs->{projects} || !(scalar @{$new_prefs->{projects}})) { 
		return { Code => 1, Description => "No boxes found in settings file.  Import canceled." }; 
	}
	
	# load existing prefs for comparison
	my $prefs_raw = load_file($self->{prefs_file});
	my $prefs = {};
	if ($prefs_raw) {
		eval { $prefs = json_parse( $prefs_raw ); };
	}
	$prefs->{projects} ||= [];
	
	# smart-merge settings (unique key is localpath-hostname-username-remote-path)
	# also deactivate new projects, as they will need passwords re-entered
	my $num_added = 0;
	my $num_merged = 0;
	
	foreach my $new_project (@{$new_prefs->{projects}}) {
		my $new_proj_key = join('-', $new_project->{local_base_dir}, $new_project->{remote_hostname}, $new_project->{rsync_username}, $new_project->{remote_base_dir});
		my $found = 0;
		
		foreach my $project (@{$prefs->{projects}}) {
			my $proj_key = join('-', $project->{local_base_dir}, $project->{remote_hostname}, $project->{rsync_username}, $project->{remote_base_dir});
			if ($proj_key eq $new_proj_key) {
				# key matches, merge project in
				foreach my $key (keys %$project) { delete $project->{$key}; }
				foreach my $key (keys %$new_project) { $project->{$key} = $new_project->{$key}; }
				$found = 1;
				$num_merged++;
				last;
			}
		} # foreach old project
		if (!$found) {
			# no match, add new project, but disable it
			$new_project->{enabled} = 0;
			
			# clear password fields, as they will need to be re-entered
			# $new_project->{rsync_password} = '';
			# $new_project->{rsync_ssh_key_passphrase} = '';
			
			push @{$prefs->{projects}}, $new_project;
			$num_added++;
		}
	} # foreach new project
	
	# overwrite settings file (daemon will auto-detect change)
	if (!save_file( $self->{prefs_file}, json_compose($prefs) )) {
		return { Code => 1, Description => "Failed to save prefs file: $prefs_file: $!" };
	}
	
	# alert user about action, and about passwords if required
	my $total_imported = $num_added + $num_merged;
	my $msg = '';
	if ($total_imported == 1) {
		if ($num_added == 1) { $msg .= "1 new box was added."; }
		else { $msg .= "1 box was imported, and it replaced an existing one."; }
	}
	else {
		$msg .= "A total of $total_imported boxes were imported ($num_added added and $num_merged replaced existing).";
	}
	$msg .= ". Please note that you may have to re-enter passwords for your imported boxes.";
	$self->call_applescript( join("\n", 
		'tell application "OpenBox"',
		'activate',
		'display alert "Settings Imported Successfully" message "'.$msg.'" as informational',
		'end tell'
	) );
	
	# return new settings for UI
	return { Code => 0, Description => "Success", Preferences => $prefs };
}

sub api_open_log_file {
	# launch log file using OS X
	my ($self, $json, $daemon, $request, $socket) = @_;
	
	my $log_file = $ENV{'HOME'} . '/Library/Logs/OpenBox-rsync.log.txt';
	if (!(-e $log_file)) {
		save_file( $log_file, "(This log will contain details about all OpenBox file transfers)\n\n" );
	}
	
	# shell out to os x "open" command-line utility
	`open $log_file`;
	
	return { Code => 0, Description => "Success" };
}

sub api_get_status {
	# get status for all projects, plus global rsync stats
	# The UI polls this from the 'Status' tab
	my ($self, $json, $daemon, $request, $socket) = @_;
	
	my $stats_file = $self->{config}->{TempDir} . '/global-stats.json';
	my $stats = undef;
	eval { $stats = json_parse( load_file($stats_file) || '{}' ); };
	if (!$stats) { $stats = {}; }
	
	$stats->{projects} = [];
	if ($json->{project_ids}) {
		foreach my $project_id (@{$json->{project_ids}}) {
			my $project_status_file = $self->{config}->{TempDir} . '/project-status-' . $project_id . '.json';
			my $project_status = undef;
			eval { $project_status = json_parse( load_file($project_status_file) || '{}' ); };
			if (!$project_status) { $project_status = {}; }
			$project_status->{code} ||= 0;
			$project_status->{description} ||= '';
			$project_status->{date} ||= time();
			$project_status->{id} = $project_id;
			push @{$stats->{projects}}, $project_status;
		} # foreach enabled project
	} # json has project ids
	
	return { Code => 0, Status => $stats };
}

sub api_reset_stats {
	# reset upload/download stats
	my ($self, $json, $daemon, $request, $socket) = @_;
	
	my $stats_file = $self->{config}->{TempDir} . '/global-stats.json';
	unlink $stats_file;
	
	return { Code => 0, Description => "Success" };
}

sub api_check_auto_ssh_key {
	# user has selected to auth via ssh key, but has left the ssh key file blank
	# so let's look for a compatible file
	my ($self, $json, $daemon, $request, $socket) = @_;
	
	my $ssh_dir = $ENV{'HOME'} . '/.ssh';
	$self->log_debug(5, "Checking for SSH keys in user dir: $ssh_dir/");
	
	my $key_file = '';
	foreach my $filename ('id_rsa', 'id_dsa', 'identity') {
		my $file = $ssh_dir . '/' . $filename;
		if ((-f $file) && (-r $file) && (-s $file)) {
			# exists, is plain file, is readable by us, and has non-zero size
			$self->log_debug(5, "Found key: $file");
			$key_file = $file;
			last;
		}
	}
	
	return { Code => ($key_file ? 0 : 1), KeyFile => $key_file };
}

sub api_check_ssh_key_pass {
	# check if user's ssh key is encrypted (requires a passphrase)
	# and if so, prompt them for it immediately
	my ($self, $json, $daemon, $request, $socket) = @_;
	
	my $passphrase = '';
	my $contents = load_file( $json->{rsync_ssh_key_file} );
	if ($contents =~ /ENCRYPTED/) {
		
		# see if we already have the user's ssh key passphrase
		$passphrase = $self->find_password_in_keychain( 'key', $json->{rsync_username}, $json->{rsync_ssh_key_file} );
		if (length($passphrase)) {
			return { Code => 0, Passphrase => $passphrase };
		}
		
		my $result = $self->call_applescript( join("\n", 
			'tell application "OpenBox"',
			'activate',
			'display dialog "Your SSH private key requires a passphrase.  Please enter it here, and OpenBox will save it securely in your Keychain." default answer "" with title "SSH Private Key Passphrase" with icon 1 with hidden answer',
			'text returned of result',
			'end tell'
		) );
		chomp $result;
		if ($result =~ /(execution\s+error|User\s+canceled)/) {
			return { Code => 1, Description => $result };
		}
		elsif ($result !~ /\S/) {
			return { Code => 1, Description => "User did not enter a passphrase." };
		}
		$passphrase = $result;
	} # encrypted key
	
	return { Code => 0, Passphrase => $passphrase };
}

sub api_check_host_to_ip {
	# make sure hostname can resolve to ip address
	my ($self, $json, $daemon, $request, $socket) = @_;
	
	$self->log_debug(5, "Converting hostname to ip: " . $json->{remote_hostname});
	my $packed_ip = undef;
	
	local $SIG{ALRM} = sub { die "Timeout\n" };
	alarm 5;
	eval { $packed_ip = scalar gethostbyname($json->{remote_hostname}); };
	alarm 0;
	
	if ($packed_ip) { 
		my $unpacked_ip = join('.', unpack('C4', $packed_ip));
		$self->log_debug(5, "Got IP: $unpacked_ip");
		return { Code => 0, Description => "Success", IP => $unpacked_ip };
	}
	else {
		my $err = ($@ ? $@ : $!) || 'Unknown error'; chomp $err;
		my $msg = "Failed to resolve hostname to IP address: " . $json->{remote_hostname};
		$self->log_debug(5, $msg);
		return { Code => 1, Description => $msg };
	}
}

sub api_check_ssh_port {
	# make sure server is listening on ssh port
	my ($self, $json, $daemon, $request, $socket) = @_;
	my $port = $json->{rsync_ssh_port} || 22;
	
	$self->log_debug(5, "Checking SSH connection: " . $json->{remote_hostname} . ":$port");
	
	my $socket = undef;
	local $SIG{ALRM} = sub { die "Timeout\n" };
	alarm 5;
	eval {
		$socket = IO::Socket::INET->new(
			PeerAddr => $json->{remote_hostname},
			PeerPort => $port,
			Proto => "tcp",
			Type => SOCK_STREAM,
			Timeout => 5
		);
	};
	alarm 0;
	
	if ($socket) {
		$self->log_debug(5, "Successfully connected to: " . $json->{remote_hostname} . ":$port");
		return { Code => 0, Description => "Success" };
	}
	else {
		my $err = ($@ ? $@ : $!) || 'Unknown error'; chomp $err;
		my $msg = "Failed to connect to remote server: $err";
		$self->log_debug(5, $msg);
		return { Code => 1, Description => $msg };
	}
}

sub api_check_ssh_dir {
	# make real ssh connection to server and test permissions, etc.
	my ($self, $json, $daemon, $request, $socket) = @_;
	
	# create faux project object to use daemon utility functions
	my $project = {
		prefs => $json
	};
	my $prefs = $json;
	
	my $username = $prefs->{rsync_username} || $ENV{'USER'};
	
	# fetch password or passphrase from keychain, if required
	if ($prefs->{rsync_password} && ($prefs->{rsync_password} eq '_OB_KEYCHAIN_')) {
		my $password = $self->find_password_in_keychain( 'pass', $prefs->{rsync_username}, $prefs->{remote_hostname} );
		if (!length($password)) { return { Code => 1, Description => "Failed to fetch password from keychain." }; }
		$prefs->{rsync_password} = $password;
	}
	elsif ($prefs->{rsync_ssh_key_passphrase} && ($prefs->{rsync_ssh_key_passphrase} eq '_OB_KEYCHAIN_')) {
		my $password = $self->find_password_in_keychain( 'key', $prefs->{rsync_username}, $prefs->{rsync_ssh_key_file} );
		if (!length($password)) { return { Code => 1, Description => "Failed to fetch SSH private key passphrase from keychain." }; }
		$prefs->{rsync_ssh_key_passphrase} = $password;
	}
	
	my $cmd = '';
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
	
	$cmd .= ' ' . $prefs->{remote_hostname};
	$cmd .= ' "echo _OPENBOX_CONNECTED_ && mkdir -p '.$prefs->{remote_base_dir}.' && touch '.$prefs->{remote_base_dir}.' && echo _OPENBOX_PERMS_GOOD_ && which rsync && echo _OPENBOX_SUCCESS_"';
	
	$self->log_debug(9, "Executing ssh test command: $cmd");
	
	# don't use ssh-agent, as we manage the ssh key passphrase ourselves
	delete $ENV{'SSH_AUTH_SOCK'};
	
	my $pty = IO::Pty::Easy->new;
	$pty->spawn($cmd . ' 2>&1');
	my $sent_pass = 0;
	my $result = '';
	my $time_start = time();
	
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
			foreach my $line (split(/\n/, $buffer)) {
				chomp $line; $line =~ s/^\s+//; $line =~ s/\s+$//;
				$result .= "$line\n";
			} # foreach line
		}
		
		if ((time() - $time_start) >= 5) {
			$pty->close();
			$result .= "Timeout";
			last;
		}
	} # while pty is active
	
	$self->log_debug(9, "Result from ssh test: $result");
		
	return { Code => 0, Result => $result };
}

sub api_set_start_on_login {
	# enable or disable auto-start on login (daemon, not UI)
	my ($self, $json, $daemon, $request, $socket) = @_;
	
	my $dir = getcwd();
	my $plist_file = $ENV{'HOME'} . '/Library/LaunchAgents/' . $self->{config}->{LaunchAgentConfigFilename};
	
	if ($json->{start_on_login} eq 1) {
		# enable start on login
		my $plist_raw = load_file( '../Resources/launchd-template.plist' );
		$plist_raw =~ s@_OPENBOXSYNCD_PATH_HERE_@$dir/openboxsyncd.pl@;
		$plist_raw =~ s@_OPENBOXSYNCD_CWD_HERE_@$dir@;
		
		my $la_dir = dirname($plist_file);
		if (!(-d $la_dir)) { `mkdir -p $la_dir`; }
		
		if (!save_file( $plist_file, $plist_raw )) {
			return { Code => 1, Description => "Could not enable launch on login.  Please reboot or repair permissions." };
		}
		chmod 0644, $plist_file;
		chmod 0755, 'openboxsyncd.pl'; # no group write, no world write (apple requirements)
	}
	else {
		# disable start on login
		unlink $plist_file;
	}
	
	return { Code => 0, Description => "Success" };
}

sub api_file { 
   ## 
   # Serve up any static file from disk, use PATH_INFO: /api/file/ABSOLUTE/PATH/TO/FILE.JPG 
   ## 
   my ($self, $json, $daemon, $request, $socket) = @_; 
    
   my $uri = $request->url(); 
   if ($uri =~ m@^/api/file(.+)$@) { 
      my $file = uri_unescape($1); 
      if (-e $file) { 
         $daemon->send_file( $file ); 
      } 
      else { 
         $daemon->send_response( 404, "File Not Found", "File Not Found: $uri" ); 
      } 
   } 
   else { 
      $daemon->send_response( 400, "Bad Request", "Bad Request: $uri" ); 
   } 
    
   $self->{output_sent} = 1; 
}

sub api_get_config {
	my ($self, $json, $daemon, $request, $socket) = @_;
	
	my $plist_file = $ENV{'HOME'} . '/Library/LaunchAgents/' . $self->{config}->{LaunchAgentConfigFilename};
	my $plist_exists = (-e $plist_file) ? 1 : 0;
	
	return { Code => 0, Description => "Success", Config => $self->{config}, StartOnLogin => $plist_exists };
}

sub api_applescript {
	##
	# Run a snippet of AppleScript and capture the output
	##
	my ($self, $json, $daemon, $request, $socket) = @_;
	
	my $result = '';
	if ($json->{code}) {
		$result = $self->call_applescript( $json->{code} );
	}
	elsif ($json->{file}) {
		$result = `/usr/bin/osascript "$json->{file}" 2>&1`;
	}
	chomp $result;
	
	return { Code => 0, Description => "Success", Result => $result };
}

sub api_shell {
	##
	# Execute a shell command and capture the output
	##
	my ($self, $json, $daemon, $request, $socket) = @_;
	
	my $cmd = $json->{command};
	$self->log_debug(9, "Executing shell command: $cmd");
	
	my $result = `$cmd 2>&1`;
	chomp $result;
	
	return { Code => 0, Description => "Success", Result => $result };
}

sub api_launch {
	##
	# Launch application by name, or file by path, or URL in default browser
	##
	my ($self, $json, $daemon, $request, $socket) = @_;
		
	my $cmd = '';
	if ($json->{app}) {
		$cmd = '/usr/bin/open -a "'.$json->{app}.'"';
	}
	elsif ($json->{file}) {
		$cmd = '/usr/bin/open "'.$json->{file}.'"';
	}
	elsif ($json->{url}) {
		$cmd = '/usr/bin/open "'.$json->{url}.'"';
	}
	else {
		return { Code => 1, Description => "Could not find anything to launch!" };
	}
	
	$self->log_debug(9, "Executing shell command: $cmd");
	system( $cmd );
	
	return { Code => 0, Description => "Success" };
}

sub api_load_prefs {
	##
	# Load user prefs
	##
	my ($self, $json, $daemon, $request, $socket) = @_;
	
	my $prefs_file = $self->{prefs_file};
	$self->log_debug(5, "Loading prefs: $prefs_file");
	
	if (-e $prefs_file) {
		my $prefs = undef;
		eval { $prefs = json_parse( load_file($prefs_file) ); };
		if (!$@ && $prefs) {
			return { Code => 0, Description => "Success", Preferences => $prefs };
		}
		else {
			$self->log_debug(1, "Corrupted prefs file, starting fresh: $@");
		}
	}
	return { Code => 0, Description => "Success", Preferences => {} };
}

sub api_save_prefs {
	##
	# Save user prefs
	##
	my ($self, $json, $daemon, $request, $socket) = @_;
	
	my $prefs_file = $self->{prefs_file};
	$self->log_debug(5, "Saving prefs: $prefs_file");
	
	# Store all passwords in OS X keychain, and remove from json file
	$json->{projects} ||= [];
	foreach my $project (@{$json->{projects}}) {
		if ($project->{rsync_password} && ($project->{rsync_password} ne '_OB_KEYCHAIN_')) {
			if (!$self->store_password_in_keychain( 'pass', $project->{rsync_username}, $project->{remote_hostname}, $project->{rsync_password} )) {
				return { Code => 1, Description => "Failed to store password in keychain." };
			}
			$project->{rsync_password} = '_OB_KEYCHAIN_';
			
			# create flag file to be picked up by sync daemon child
			if ($json->{daemon_enabled}) {
				save_file( $self->{config}->{TempDir} . '/update-password-'.$project->{id}.'.txt', '1' );
			}
		} # move rsync_password to keychain
		
		if ($project->{rsync_ssh_key_passphrase} && ($project->{rsync_ssh_key_passphrase} !~ /^(_OB_KEYCHAIN_|_OB_NOPASS_)$/)) {
			if (!$self->store_password_in_keychain( 'key', $project->{rsync_username}, $project->{rsync_ssh_key_file}, $project->{rsync_ssh_key_passphrase} )) {
				return { Code => 1, Description => "Failed to store SSH private key passphrase in keychain." };
			}
			$project->{rsync_ssh_key_passphrase} = '_OB_KEYCHAIN_';
			
			# create flag file to be picked up by sync daemon child
			if ($json->{daemon_enabled}) {
				save_file( $self->{config}->{TempDir} . '/update-password-'.$project->{id}.'.txt', '1' );
			}
		} # move rsync_password to keychain
		
		if ($project->{two_way_delete_safety}) {
			# create two-way delete safety flag, so daemon performs initial two-way sync without delete, then turns it back on
			$self->log_debug(5, "Writing two-way safety delete flag for project: " . $project->{id});
			save_file( $self->{config}->{TempDir} . '/two-way-delete-safety-'.$project->{id}.'.txt', '1' );
			delete $project->{two_way_delete_safety};
		}
	} # foreach project
	
	if (!save_file( $prefs_file, json_compose($json) )) {
		return { Code => 1, Description => "Failed to save prefs file: $prefs_file: $!" };
	}
	
	return { Code => 0, Description => "Success" };
}

1;


























