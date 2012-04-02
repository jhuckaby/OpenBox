# OpenBox Utilities
# Used by openboxsyncd.pl and openbox-ui.pl
# Copyright (c) 2012 Joseph Huckaby
# Released under the MIT License.

sub call_keychain {
	# shell out to security binary to create or locate passwords in keychain
	my ($self, $action, $args) = @_;
	
	my $sec_trick = $self->{config}->{TempDir} . '/OpenBox';
	my $cmd = "$sec_trick $action";
	foreach my $key (sort keys %$args) {
		my $value_esc = $args->{$key}; $value_esc =~ s/\"/\\"/g;
		$cmd .= " $key";
		if (length($value_esc)) { $cmd .= ' "'.$value_esc.'"'; }
	}
	$cmd .= ' 2>&1 1>/dev/null';
	
	$self->log_debug(9, "Executing keychain command: $cmd");
	my $result = `$cmd`;
	# $self->log_debug(9, "Keychain Result: $result"); # warning: log will contain plaintext password
	
	return $result;
}

sub find_password_in_keychain {
	# locate server or private key password in keychain
	my ($self, $auth_type, $username, $service) = @_;
	
	my $action = ($auth_type eq 'pass') ? 'find-internet-password' : 'find-generic-password';
	my $result = $self->call_keychain( $action, {
		"-a" => $username,
		"-s" => $service,
		"-g" => ""
	} );
	
	# password: "12345"
	if ($result =~ /\bpassword\:\s*\"(.+)\"/) {
		return $1;
	}
	
	# password: 0x7E21402324255E262A28295B5D7B7D5C3B273A222C2E3C3E2F3F
	elsif ($result =~ /\bpassword\:\s*0x([0-9A-F]+)/) {
		my $password = $1;
		$password =~ s/([0-9A-F]{2})/ chr(hex($1)); /eg;
		return $password;
	}
	
	# error or not found
	else {
		return '';
	}
}

sub store_password_in_keychain {
	# store server or private key password in keychain
	my ($self, $auth_type, $username, $service, $password) = @_;
	
	my $action = '';
	my $keychain_args = {
		"-a" => $username,
		"-s" => $service,
		"-w" => $password,
		"-U" => ""
	};
	
	# if password doesn't exist, add -T flag for access
	if (!length($self->find_password_in_keychain($auth_type, $username, $service))) {
		my $sec_trick = $self->{config}->{TempDir} . '/OpenBox';
		$keychain_args->{"-T"} = "$sec_trick";
	}
	
	if ($auth_type eq 'pass') {
		$action = 'add-internet-password';
		$keychain_args->{"-D"} = "Internet password";
		$keychain_args->{"-l"} = "OpenBox ($service)";
		$keychain_args->{"-r"} = "sftp";
	}
	elsif ($auth_type eq 'key') {
		$action = 'add-generic-password';
		$keychain_args->{"-D"} = "application password";
		$keychain_args->{"-l"} = "OpenBox (SSH Private Key)";
	}
	else {
		$self->log_debug(1, "Invalid authentication type: $auth_type");
		return 0;
	}
	
	my $result = $self->call_keychain( $action, $keychain_args );
	if ($result =~ /\S/) { return 0; } # error
	else { return 1; } # success
}

sub call_applescript {
	# invoke applescript given chunk of script code
	my ($self, $scpt) = @_;
	
	my $temp_file = '/var/tmp/script_'.$$.'.scpt';
	save_file( $temp_file, $scpt );
	my $result = `/usr/bin/osascript $temp_file 2>&1`;
	unlink $temp_file;
	
	return $result;
}

sub call_dialog {
	# invoke CocoaDialog and return result
	my ($self, $runmode, $args) = @_;
	
	my $cmd = './CocoaDialog/Contents/MacOS/CocoaDialog ' . $runmode;
	foreach my $key (keys %$args) {
		my $value = $args->{$key};
		$value =~ s/\"/\\"/g;
		$cmd .= ' --' . $key . ' "' . $value . '"';
	}
	
	$self->log_debug(9, "Calling CocoaDialog: $cmd");
	$result = `$cmd 2>&1`;
	chomp $result;
	
	$self->log_debug(9, "Result: $result");
	
	return $result;
}

sub import_param {
	##
	# Import Parameter into hash ref.  Dynamically create arrays for keys
	# with multiple values.
	##
	my ($operator, $key, $value) = @_;

	$value = uri_unescape( $value );
	
	if ($operator->{$key}) {
		if (isa($operator->{$key}, 'ARRAY')) {
			push @{$operator->{$key}}, $value;
		}
		else {
			$operator->{$key} = [ $operator->{$key}, $value ];
		}
	}
	else {
		$operator->{$key} = $value;
	}
}

sub parse_query {
	##
	# Parse query string into hash ref
	##
	my $uri = shift;
	my $query = {};
	
	$uri =~ s@^.*\?@@; # strip off everything before ?
	$uri =~ s/([\w\-\.\/]+)\=([^\&]*)\&?/ import_param($query, $1, $2); ''; /eg;
	
	return $query;
}

sub compose_query {
	##
	# Compose query string
	##
	my $params = shift;
	my $string = shift || '';
	
	foreach my $key (sort keys %$params) {
		if ($string =~ /\?/) { $string .= '&'; } else { $string .= '?'; }
		$string .= $key . '=' . uri_escape($params->{$key});
	}
	
	return $string;
}

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
	my $file = shift;
	my $contents = shift;

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

sub secure_delete_file {
	# securely delete file (overwrite 1x, flush, then unlink)
	my $file = shift;
	my $size = (stat($file))[7];
	my $fh = FileHandle->new(">$file");
	if ($fh) {
		$fh->print( 'X' . $size );
		$fh->flush();
		$fh->close();
		return unlink $file;
	}
	return 0;
}

sub find_object {
	# search array of objects for keys/values matching criteria
	# return first object found
	my ($arr, $crit, $mode) = @_;
	$mode ||= 'AND';
	my $min_matches = ($mode eq 'AND') ? (scalar keys %$crit) : 1;
	
	foreach my $elem (@$arr) {
		my $matches = 0;
		foreach my $key (keys %$crit) {
			my $value = $crit->{$key};
			if (defined($elem->{$key}) && ($elem->{$key} eq $value)) { $matches++; }
		}
		if ($matches >= $min_matches) { return $elem; }
	}
	
	return 0;
}

sub find_object_idx {
	# search array of objects for keys/values matching criteria
	# return idx of first object found, or -1 for no match
	my ($arr, $crit, $mode) = @_;
	$mode ||= 'AND';
	my $min_matches = ($mode eq 'AND') ? (scalar keys %$crit) : 1;
	
	my $idx = 0;
	foreach my $elem (@$arr) {
		my $matches = 0;
		foreach my $key (keys %$crit) {
			my $value = $crit->{$key};
			if (defined($elem->{$key}) && ($elem->{$key} eq $value)) { $matches++; }
		}
		if ($matches >= $min_matches) { return $idx; }
		$idx++;
	}
	
	return -1;
}

1;
