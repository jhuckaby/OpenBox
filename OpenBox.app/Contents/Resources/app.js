// OpenBox 1.0 Main App Script
// (c) 2012 Joseph Huckaby
// Released under the MIT License.

var OpenBox = {
	
	currentPageID: '',
	editWindow: null,
	
	init: function() {
		// copy prefs into OpenBox object (so popup windows can access it)
		this.prefs = prefs;
		
		// attach click listeners to all tabs
		$('span.tab').click( function(e) {
			OpenBox.clickTab( $(this).attr('id').replace(/^tab_/, '') );
		} );
		
		// make links work
		$("a[target='_blank']").mouseup( function(e) {
			var url = $(this).attr('href');
			OpenBox.apiPost('launch', { url: url } );
		} );
		
		// add actions for checkboxes
		$('input.cb_ob_enabled').change( function(e) {
			var checked = $(this).prop('checked');
			prefs.daemon_enabled = checked ? 1 : 0;
			OpenBox.apiPost('save_prefs', prefs);
			
			// if turning master-switch off, start on login must be off too
			if ((start_on_login == 1) && (prefs.daemon_enabled != 1)) {
				start_on_login = 0;
				$('input.cb_ob_start_on_login').prop('checked', false);
				OpenBox.apiPost('set_start_on_login', { start_on_login: 0, auto_error: 1 });
			}
		} );
		$('input.cb_ob_start_on_login').change( function(e) {
			var checked = $(this).prop('checked');
			start_on_login = checked ? 1 : 0;
			OpenBox.apiPost('set_start_on_login', { start_on_login: start_on_login, auto_error: 1 });
			
			// if turning start-on-login on, daemon must also be running
			if ((start_on_login == 1) && (prefs.daemon_enabled != 1)) {
				prefs.daemon_enabled = 1;
				$('input.cb_ob_enabled').prop('checked', true);
				OpenBox.apiPost('save_prefs', prefs);
			}
		} );
		
		// hook enter key on text fields
		$('#es_remote_hostname, #es_rsync_username, #es_rsync_password, #es_remote_base_dir').keydown( function(event) {
			if (event.keyCode == '13') { // enter key
				event.preventDefault();
				$P().saveSettings();
			}
		} );
		
		// call no-op applescript cmd to initialize applescript framework
		// (sometimes there is a huge delay before applescript responds)
		var applscpt = [
			'tell application "OpenBox"',
			'activate',
			'end tell'
		].join("\n");
		OpenBox.apiPost('applescript', { code: applscpt } );
	},
	
	clickTab: function(id) {
		// switch page
		Dialog.hide();
		
		if (this.currentPageID) {
			if (this.pages[this.currentPageID].onDeactivate) {
				this.pages[this.currentPageID].onDeactivate();
			}
		}
		
		$('div.page').hide();
		$('span.tab').removeClass('selected');
		
		$('#page_'+id).show();
		$('#tab_'+id).addClass('selected');
		
		var page = this.pages[id];
		if (page.onActivate) page.onActivate();
		
		this.currentPageID = id;
	},
	
	apiPost: function(cmd, params, callback) {
		// send AJAX request to local app server
		if (!params) params = {};
		$.ajax({
			type: "POST",
			url: api_url + "api/" + cmd,
			data: JSON.stringify(params),
			dataType: 'json'
		})
		.success( function(resp) {
			// fire callback or generic response handler
			if (resp.Code) Dialog.hide(); // hide dialog on error
			if (callback) callback(resp, cmd, params);
		} );
	},
	
	clearError: function() {
		// clear error state
		$('.invalid').removeClass('invalid');
	},
	
	badField: function(id) {
		// mark field as bad
		$('#'+id).addClass('invalid').focus();
	},
	
	doError: function(msg, callback) {
		// show error using an applescript dialog
		Dialog.hide();
		$('button').removeAttr('disabled');
		
		var applscpt = [
			'tell application "OpenBox"',
				'activate',
				'display alert "Sorry, an OpenBox error occurred:" message "'+msg.replace(/([\"\n])/g, "\\$1")+'" as warning',
			'end tell'
		].join("\n");
		
		OpenBox.apiPost('applescript', { code: applscpt }, callback || null );
	},
	
	generateUniqueID: function() {
		// generate semi-unique ID for new projects
		var date = new Date();
		return '' + username + date.getTime().toString().replace(/\D+/g, '') + Math.floor(Math.random() * 10000);
	},
	
	generateNewProject: function() {
		// generate new project with standard settings
		return {
			"id": OpenBox.generateUniqueID(),
			"enabled": 1,
			"title": '',
			"local_base_dir": home_dir + '/Documents',
			"remote_base_dir": '~/',
			"remote_hostname": '',
			"rsync_username": username,
			"rsync_auth_type": "pass",
			"rsync_password": '',
			"rsync_ssh_key_file": '',
			"rsync_symlinks": 'preserve',
			"rsync_delete": 0,
			"rsync_timeout": 0,
			"rsync_kbrate": 0,
			"rsync_compress": 1,
			"rsync_update": 1,
			"auto_downsync": 0,
			"rsync_backup": 0,
			"startup_sync": 1,
			"rsync_users_groups": 0,
			"ssh_options": "-oGSSAPIKeyExchange=no -oStrictHostKeyChecking=no -oCheckHostIP=no -oConnectionAttempts=1 -oNumberOfPasswordPrompts=1",
			"exclude_files": "/RCS /SCCS /CVS /CVS.adm /RCSLOG /cvslog.* /tags /TAGS /core /*~ /#* /,* /_$* /*$ /*.old /*.bak /*.BAK /*.orig /*.rej /*.elc /*.ln /*.tmp /*.temp /.*",
			"include_files": "",
			"growl": 1,
			"growl_sync_start": 0,
			"growl_sync_end": 1,
			"growl_errors": 1
		};
	},
	
	openEditWindow: function(args) {
		// open window for adding/editing project
		// gotta jump through some hoops to connect the windows and pass data around
		if (this.editWindow) this.editWindow.close();
		
		var size = { width: 600, height: 570 };
		
		this.editWindow = App.createWindow({
		  uri: 'edit.html',
		  rect: { 
			origin: {x: Math.floor((screen.width / 2) - (size.width / 2)) , y: Math.floor((screen.height / 2) - (size.height / 2)) + 30},
			size: size
		  },
		  style: { 
			closable: true,
			textured: false,
			resizable: false
		  }
		});
		this.editWindow.makeKeyAndOrderFront();
		
		// have to wait for 'document' object to appear in window for comm
		var timer = setInterval( function() {
			if (OpenBox.editWindow.document && OpenBox.editWindow.document.obInit) {
				OpenBox.editWindow.document.obInit( OpenBox, args );
				clearInterval(timer);
			}
		}, 50 );
	},
	
	closeEditWindow: function() {
		// close edit window if open
		if (this.editWindow) {
			this.editWindow.close();
			delete this.editWindow;
		}
	},
	
	cleanupPasswords: function() {
		// fix up passwords after prefs save
		for (var idx = 0, len = prefs.projects.length; idx < len; idx++) {
			var project = prefs.projects[idx];
			if (project.rsync_ssh_key_passphrase && !project.rsync_ssh_key_passphrase.match(/^(_OB_KEYCHAIN_|_OB_NOPASS_)$/)) {
				project.rsync_ssh_key_passphrase = '_OB_KEYCHAIN_';
			}
			if (project.rsync_password && !project.rsync_password.match(/^(_OB_KEYCHAIN_)$/)) {
				project.rsync_password = '_OB_KEYCHAIN_';
			}
			delete project.two_way_delete_safety;
		}
	},
	
	pages: {
		easy: {
			project: null,
			
			onActivate: function() {
				// activate easy setup page
				if (!prefs.projects) prefs.projects = [];
				var project = find_object( prefs.projects, { easy: 1 } );
				if (!project) {
					project = OpenBox.generateNewProject();
					project.easy = 1;
					project.first = 1;
					prefs.projects.push( project );
				}
				this.project = project;
				
				$('#es_local_base_dir').html( basename(project.local_base_dir) ).attr('title', project.local_base_dir);
				$('#es_remote_hostname').val( project.remote_hostname || '' );
				$('#es_rsync_username').val( project.rsync_username || '' );
				$('#es_rsync_password').val( project.rsync_password || '' );
				$('#es_rsync_ssh_key_file').html( project.rsync_ssh_key_file ? basename(project.rsync_ssh_key_file) : '(Automatic)' );
				$('#es_remote_base_dir').val( project.remote_base_dir || '/' );
				this.setAuthType( project.rsync_auth_type || 'pass' );
			},
			
			selectLocalBaseDir: function() {
				// prompt user to select local base dir
				$('button').attr('disabled', 'disabled');
				OpenBox.apiPost('dialog', {
					'mode': 'fileselect',
					'text': "Select the local folder to synchronize:",
					'select-directories': 1,
					'select-only-directories': 1
				}, function(resp) {
					$('button').removeAttr('disabled');
					var path = trim( resp.Result || '' );
					if (path == '/') {
						OpenBox.doError("Sorry, you cannot sync the root directory of the boot drive.  Chaos would ensue.");
					}
					else if (path.match(/\S/)) {
						path = path.replace(/\/$/, '');
						$P().project.local_base_dir = path;
						$('#es_local_base_dir').html( basename(path) ).attr('title', path);
					}
				} );
			},
			
			setAuthType: function(type) {
				// set authentication type (pass or key)
				$('#es_auth_type').val(type);
				$('.auth_pass, .auth_key').hide();
				$('.auth_'+type).show();
				if (this.project) this.project.rsync_auth_type = type;
				OpenBox.clearError();
			},
			
			selectSSHKeyFile: function() {
				// prompt user for ssh key file
				$('button').attr('disabled', 'disabled');
				OpenBox.apiPost('dialog', {
					'mode': 'fileselect',
					'text': "Select your SSH private key file to use:",
					'with-directory': ssh_key_dir
				}, function(resp) {
					$('button').removeAttr('disabled');
					var path = trim( resp.Result || '' );
					if (path.match(/\S/)) {
						path = path.replace(/\/$/, '');
						$P().project.rsync_ssh_key_file = path;
						$P().project.rsync_ssh_key_passphrase = '';
						$('#es_rsync_ssh_key_file').html( basename(path) );
					}
					else {
						$P().project.rsync_ssh_key_file = '';
						$P().project.rsync_ssh_key_passphrase = '';
						$('#es_rsync_ssh_key_file').html( "(Automatic)" );
					}
				} );
			},
			
			saveSettings: function() {
				// validate form, import values into project
				var project = this.project;
				OpenBox.clearError();
				$('button').attr('disabled', 'disabled');
				
				project.remote_hostname = $('#es_remote_hostname').val();
				if (!project.remote_hostname.match(/^[\w\-\.]+$/)) return OpenBox.badField('es_remote_hostname');
				
				project.rsync_username = $('#es_rsync_username').val();
				if (!project.rsync_username.length) return OpenBox.badField('es_rsync_username');
				
				switch (project.rsync_auth_type) {
					case 'pass':
						project.rsync_password = $('#es_rsync_password').val();
						if (!project.rsync_password.length) return OpenBox.badField('es_rsync_password');
						
						project.rsync_ssh_key_file = '';
						project.rsync_ssh_key_passphrase = '';
					break;
					
					case 'key':
						project.rsync_password = '';
					break;
				}
				
				project.remote_base_dir = trim( $('#es_remote_base_dir').val() );
				if (!project.remote_base_dir.length) return OpenBox.badField('es_remote_base_dir');				
				project.remote_base_dir = project.remote_base_dir.replace(/\/$/, '');
				
				// show progress dialog
				Dialog.showProgress("Validating settings...");
				this.saveSettings_start();
			},
			
			saveSettings_start: function() {
				// begin saving settings
				var project = this.project;
				if (project.rsync_auth_type == 'key') {
					if (project.rsync_ssh_key_file) {
						// check key file for passphrase if needed
						this.saveSettings_checkSSHKeyPassphrase();
					}
					else {
						// no key specified (auto), scan for one in the usual place
						OpenBox.apiPost('check_auto_ssh_key', {}, function(resp) {
							if (resp.Code == 0) {
								// got one
								project.rsync_ssh_key_file = resp.KeyFile;
								$P().saveSettings_checkSSHKeyPassphrase();
							}
							else {
								// nope
								OpenBox.doError("Failed to locate a compatible private key in your SSH folder.  Please select it manually.");
							}
						} );
					}
				} // auth type is key
				else this.saveSettings_checkServer();
			},
			
			saveSettings_checkSSHKeyPassphrase: function() {
				// check ssh key for passphrase, or continue onward
				var project = this.project;
				if ((project.rsync_ssh_key_passphrase != '_OB_KEYCHAIN_') && (project.rsync_ssh_key_passphrase != '_OB_NOPASS_')) {
					OpenBox.apiPost('check_ssh_key_pass', project, function(resp) {
						if (resp.Code == 0) {
							// success, but key may or may not be encrypted
							resp.Passphrase = '' + resp.Passphrase;
							if (resp.Passphrase.length) {
								project.rsync_ssh_key_passphrase = resp.Passphrase;
							}
							else {
								project.rsync_ssh_key_passphrase = '_OB_NOPASS_';
							}
							$P().saveSettings_checkServer();
						}
						else {
							// error, user probably cancelled
							OpenBox.doError("Failed to get your SSH private key passphrase.");
						}
					} );
				}
				else this.saveSettings_checkServer();
			},
			
			saveSettings_checkServer: function() {
				// validate more things
				var project = this.project;
				
				Dialog.showProgress("Checking hostname...");
				OpenBox.apiPost('check_host_to_ip', project, function(resp) {
					if (resp.Code == 0) {
						Dialog.showProgress("Checking connection...");
						OpenBox.apiPost('check_ssh_port', project, function(resp) {
							if (resp.Code == 0) {
								Dialog.showProgress("Checking permissions...");
								OpenBox.apiPost('check_ssh_dir', project, function(resp) {
									if (resp.Code == 0) {
										var result = resp.Result;
										if (result.match(/_OPENBOX_SUCCESS_/)) {
											$P().saveSettings_finish();
										}
										else if (result.match(/timeout/i)) {
											// timeout (unknown error)
											OpenBox.doError("A timeout occurred attempting to connect to the server.  Please verify your information and try again.");
										}
										else if (result.match(/publickey/i)) {
											// ssh key incorrect
											if (project.rsync_auth_type == 'key') {
												if (project.rsync_ssh_key_passphrase && !project.rsync_ssh_key_passphrase.match(/_OB_NOPASS_/)) {
													project.rsync_ssh_key_passphrase = '';
													OpenBox.doError("Your SSH key passphrase was rejected.  Please verify it and try again.");
												}
												else {
													OpenBox.doError("Your SSH key was rejected by the server.  Please verify it is correct and try again.");
												}
											}
											else {
												OpenBox.doError("Your username and/or password were rejected by the server.  Please verify they are correct and try again.");
											}
										}
										else if (result.match(/password/i)) {
											// password rejected
											OpenBox.doError("Your password was rejected by the server.  Please verify it is correct and try again.");
										}
										else if (result.match(/permission/i)) {
											// permission denied
											OpenBox.doError("Your user account does not have permission to write files to the server.  Please verify your settings and try again.");
										}
										else if (result.match(/remote\s+command/)) {
											// no rsync on remote server
											OpenBox.doError("Your server does not appear to have rsync installed.  Please see OpenBox.io for server setup instructions.");
										}
										else {
											// unknown error
											OpenBox.doError("An unknown error occurred trying to SSH to the server.  Please verify your settings and try again.");
										}
									}
									else OpenBox.doError(resp.Description);
								} );
							}
							else OpenBox.doError(resp.Description);
						} );
					}
					else OpenBox.doError(resp.Description);
				} );
			},
			
			saveSettings_finish: function() {
				// all validatin done, really finish saving now
				var project = this.project;
				Dialog.showProgress("Saving settings...");
				
				// save settings
				project.enabled = 1;
				project.title = ''; // easy setup = blank title
				project.mod_date = time_now();
				
				prefs.daemon_enabled = 1; // easy setup = turn daemon on
				
				// flag for first time user mesage
				var first = false;
				if (project.first) {
					delete project.first;
					first = true;
				}
				
				OpenBox.apiPost('save_prefs', prefs, function(resp) {
					// save complete, fix up passwords
					OpenBox.cleanupPasswords();
					
					// switch to status tab
					Dialog.hide();
					$('button').removeAttr('disabled');
					OpenBox.clickTab('status');
					
					// show first time user message
					if (first) {
						var applscpt = [
							'tell application "OpenBox"',
							'activate',
							"display alert \"Easy Setup Complete\" message \"Your files will now be synchronized.  You may quit this application at any time, and OpenBox will continue to work in the background.  If you want OpenBox to start automatically, click the \\\"Start on Login\\\" checkbox.\" as informational",
							'end tell'
						].join("\n");
						OpenBox.apiPost('applescript', { code: applscpt } );
					}
				} );
			},
			
			onDeactivate: function() {
				
			}
		}, // easy page
		
		status: {
			onActivate: function() {
				// set checkbox states
				$('input.cb_ob_enabled').prop('checked', prefs.daemon_enabled == 1);
				$('input.cb_ob_start_on_login').prop('checked', start_on_login == 1);
				
				setTimeout( function() { $P('status').monitorStatus(); }, 1 );
			},
			
			monitorStatus: function() {
				// get server status and repeat every N seconds while page is active
				if (OpenBox.currentPageID == 'status') {
					// gather all enabled project ids
					var project_ids = [];
					for (var idx = 0, len = prefs.projects.length; idx < len; idx++) {
						var project = prefs.projects[idx];
						if (project.enabled == 1) project_ids.push( project.id );
					}
					
					OpenBox.apiPost('get_status', { project_ids: project_ids }, function(resp) {
						// show status onscreen
						var status = resp.Status;
						if (status) {
							// display widget for each project
							var html = '';
							
							if (status.projects && status.projects.length) {
								
								// bump active projects to the top, preserve ordering otherwise
								var sorted = [];
								for (var idx = 0, len = status.projects.length; idx < len; idx++) {
									var pstatus = status.projects[idx];
									if (typeof(pstatus.progress) != 'undefined') sorted.push(pstatus);
								}
								for (var idx = 0, len = status.projects.length; idx < len; idx++) {
									var pstatus = status.projects[idx];
									if (typeof(pstatus.progress) == 'undefined') sorted.push(pstatus);
								}
								status.projects = sorted;
								
								// render status for each project
								for (var idx = 0, len = status.projects.length; idx < len; idx++) {
									var pstatus = status.projects[idx];
									var pprefs = find_object( prefs.projects, { id: pstatus.id } );
									
									// project may have partial stats (rsync in progress)
									// if so, add them to totals (which are only updated after rsync completes)
									// JH 2012-04-03: Disabling this for now, because rsync gives us CRAP stats while in progress
									/* if (pstatus.stats) {
										for (var key in pstatus.stats) {
											if (!status[key]) status[key] = 0;
											status[key] += pstatus.stats[key];
										}
										if (!status.bytes_received) status.bytes_received = 0;
										if (!status.bytes_sent) status.bytes_sent = 0;
										if (pstatus.stats.partial_received) status.bytes_received += pstatus.stats.partial_received;
										if (pstatus.stats.partial_sent) status.bytes_sent += pstatus.stats.partial_sent;
									} */
									
									// render html for project status
									var pstate = 'Idle';
									if (pstatus.code != 0) pstate = 'Error';
									else if (typeof(pstatus.progress) != 'undefined') pstate = 'Active';
									
									html += '<div class="status_item">';
									html += '<div class="stitem_header left">' + (pprefs.title || '(Easy Setup)') + '</div>';
									html += '<div class="stitem_header right '+pstate.toLowerCase()+'">' + pstate + '</div>';
									html += '<div class="clear"></div>';
									
									html += '<div class="stitem_details '+pstate.toLowerCase()+'">';
									switch (pstate) {
										case 'Idle':
											// html += '<div class="sitem_title">Last Message:</div>';
											html += '<div class="sitem_content">Last Message: ' + (pstatus.description || '(None)') + '</div>';
										break;
										
										case 'Error':
											html += '<div class="sitem_title">Last Error:</div>';
											html += '<div class="sitem_content">' + (pstatus.description || '(None)') + '</div>';
										break;
										
										case 'Active':
											html += '<div class="sitem_title">' + pstatus.description + '</div>';
											html += '<div class="sitem_content">' + get_progress_bar(pstatus.progress, 483) + '</div>';
											var remain_html = '';
											if ((pstatus.progress > 0) && (pstatus.progress < 1.0) && ((pstatus.time_now - pstatus.time_start) >= 5)) {
												remain_html = get_nice_remaining_time( pstatus.time_start, pstatus.time_now, pstatus.progress, 1.0, false, true ) + ' remaining';
											}
											html += '<div class="stitem_date">' + remain_html + '</div>';
										break;
									}
									html += '</div>'; // stitem_details
									if (pstate != 'Active') html += '<div class="stitem_date">' + get_relative_date_html(pstatus.date, true) + '</div>';
									
									html += '</div>'; // status_item
								} // foreach project
							} // active projects
							
							// display project html
							html += '<div style="height:0px; border-top: 1px solid rgba(0,0,0,0.25);"></div>';
							$('#st_proj_stat_cont').html( html );
							
							var total_bytes_sent = get_text_from_bytes(status.bytes_sent || 0);
							var total_bytes_received = get_text_from_bytes(status.bytes_received || 0);
							var total_files_sent = commify(status.files_sent || 0);
							var total_files_received = commify(status.files_received || 0);
							
							if (status.bytes_sent && status.upsync_elapsed) {
								total_bytes_sent += ' (' + get_text_from_bytes(status.bytes_sent / status.upsync_elapsed) + '/sec)';
							}
							if (status.bytes_received && status.downsync_elapsed) {
								total_bytes_received += ' (' + get_text_from_bytes(status.bytes_received / status.downsync_elapsed) + '/sec)';
							}
														
							$('#st_stat_tfs').html( total_files_sent );
							$('#st_stat_tfr').html( total_files_received );
							$('#st_stat_tbs').html( total_bytes_sent );
							$('#st_stat_tbr').html( total_bytes_received );
							
						} // good status resp
						
						setTimeout( function() { OpenBox.pages.status.monitorStatus() }, 1000 * 2 );
					} );
				} // current page is status
			},
			
			resetStats: function() {
				// reset stats
				$('button').attr('disabled', 'disabled');
				OpenBox.apiPost('reset_stats', {}, function(resp) {
					$('button').removeAttr('disabled');
				} );
			},
			
			onDeactivate: function() {
				
			}
		}, // status page
		
		advanced: {
			selectedIdx: -1,
			
			onActivate: function() {
				// set checkbox states
				$('input.cb_ob_enabled').prop('checked', prefs.daemon_enabled == 1);
				$('input.cb_ob_start_on_login').prop('checked', start_on_login == 1);
				
				// render table of projects
				var html = '';
				html += '<table class="data_table" cellspacing="0" cellpadding="0">';
				html += '<tr><th>On</th><th>Box Name</th><th>Local Folder</th><th>Remote Path</th></tr>';
				html += '<tr><td colspan="4" style="height:1px; margin:0; padding:0;"><div style="height:1px; background:rgba(200, 200, 200, 1);"></div></td></tr>';
				
				if (prefs.projects && prefs.projects.length) {
					for (var idx = 0, len = prefs.projects.length; idx < len; idx++) {
						var project = prefs.projects[idx];
						html += '<tr box_idx="'+idx+'" '+((idx == this.selectedIdx) ? 'class="selected"' : '')+'>';
						
						html += '<td><input type="checkbox" '+((project.enabled == 1) ? 'checked="checked"' : '') + 
							' onChange="$P().setProjectEnabled('+idx+',this.checked)"/></td>';
						
						html += '<td style="max-width:100px;">'+(project.title || '(Easy Setup)')+'</td>';
						
						html += '<td><div class="folder" style="max-width:100px;" title="'+project.local_base_dir+'">'+basename(project.local_base_dir)+'</div></td>';
						
						html += '<td style="max-width:200px;">'+project.remote_hostname+':'+project.remote_base_dir+'/</td>';
						
						html += '</tr>';
					} // foreach project
				} // prefs.projects
				
				html += '</table>';
				$('#adv_table_wrapper').html( html );
				
				setTimeout( function() {
					$('#adv_table_wrapper > table > tbody > tr').mousedown( function(e) {
						// click to select row
						e.stopPropagation();
						$P().selectProject( parseInt($(this).attr('box_idx'), 10) );
						$(this).addClass('selected');
					} );
					$('#adv_table_wrapper').mousedown( function(e) {
						// clicks not on rows but inside scroll area deselect all
						e.stopPropagation();
						$P().deselectAllProjects();
					} );
					$('#adv_table_wrapper > table > tbody > tr > td > input').mousedown( function(e) {
						// prevent checkbox clicks from propagating outward and selecting/deselecting the row
						e.stopPropagation();
					} );
					
					// sync edit buttons to selection state
					if ($P().selectedIdx > -1) $('#adv_delete_box, #adv_sync_box, #adv_edit_box').show();
					else $('#adv_delete_box, #adv_sync_box, #adv_edit_box').hide();
				}, 1 );
			},
			
			selectProject: function(idx) {
				// select project
				this.selectedIdx = idx;
				$('#adv_table_wrapper > table > tbody > tr').removeClass('selected');
				$('#adv_delete_box, #adv_sync_box, #adv_edit_box').show();
				
				var now = hires_time_now();
				if (this.last_item_click) {
					if ((idx == this.last_item_idx) && ((now - this.last_item_click) <= 0.25)) {
						// double click!
						this.editSelectedProject();
					}
					else {
						this.last_item_click = now;
						this.last_item_idx = idx;
					}
				}
				else {
					this.last_item_click = now;
					this.last_item_idx = idx;
				}
			},
			
			deselectAllProjects: function() {
				// deselect all projects
				this.selectedIdx = -1;
				$('#adv_table_wrapper > table > tbody > tr').removeClass('selected');
				$('#adv_delete_box, #adv_sync_box, #adv_edit_box').hide();
			},
			
			setProjectEnabled: function(idx, checked) {
				// enable or disable project, and immediately save prefs
				var project = prefs.projects[idx];
				project.enabled = checked ? 1 : 0;
				OpenBox.apiPost('save_prefs', prefs);
			},
			
			addProject: function() {
				// pop open edit window to add new project
				OpenBox.openEditWindow({
					type: 'add',
					project: OpenBox.generateNewProject()
				});
			},
			
			addProjectFinish: function(project) {
				// finished adding project, called from popup edit window
				if (!prefs.projects) prefs.projects = [];
				prefs.projects.push( project );
				
				// save prefs async
				OpenBox.apiPost('save_prefs', prefs, function(resp) {
					OpenBox.cleanupPasswords();
				});
				
				// select our new project
				this.selectedIdx = prefs.projects.length - 1;
				
				// make sure user didn't leave the advanced tab, and refresh display
				OpenBox.clickTab('advanced');
				
				// close edit window
				setTimeout( function() { OpenBox.closeEditWindow(); }, 1 );
			},
			
			editSelectedProject: function() {
				// pop open edit window to edit current project
				this.editingIdx = this.selectedIdx;
				var project = prefs.projects[ this.selectedIdx ];
				
				OpenBox.openEditWindow({
					type: 'edit',
					project: JSON.parse( JSON.stringify(project) )
				});
			},
			
			editProjectFinish: function(project) {
				// finished adding project, called from popup edit window
				prefs.projects[ this.editingIdx ] = project;
				this.selectedIdx = this.editingIdx;
				delete this.editingIdx;
				
				// save prefs async
				OpenBox.apiPost('save_prefs', prefs, function(resp) {
					OpenBox.cleanupPasswords();
				});
				
				// make sure user didn't leave the advanced tab, and refresh display
				OpenBox.clickTab('advanced');
				
				// close edit window
				setTimeout( function() { OpenBox.closeEditWindow(); }, 1 );
			},
			
			deleteSelectedProject: function() {
				// delete selected project
				var project = prefs.projects[ this.selectedIdx ];
				
				var applscpt = [
					'tell application "OpenBox"',
					'activate',
					'set question to display dialog "Are you sure you want to delete the box \\"'+(project.title || '(Easy Setup)')+'\\"?" buttons {"Cancel", "Delete"} default button 2 with title "Delete Confirmation" with icon 1',
					'set answer to button returned of question',
					'end tell'
				].join("\n");
				
				OpenBox.apiPost('applescript', { code: applscpt }, function(resp) {
					if (resp.Result.match(/Delete/)) {
						OpenBox.closeEditWindow();
					
						var idx = $P('advanced').selectedIdx;
						prefs.projects.splice( idx, 1 );
					
						// save prefs async
						OpenBox.apiPost('save_prefs', prefs);
					
						// deselect project
						$P('advanced').selectedIdx = -1;
					
						// redraw page
						OpenBox.clickTab('advanced');
					} // confirmed
				} );
			},
			
			syncSelectedProject: function() {
				// force sync on selected project
				var project = prefs.projects[ this.selectedIdx ];
				if (!prefs.daemon_enabled) return OpenBox.doError("You must enable the OpenBox service to synchronize boxes.  The checkbox is in the upper-right corner of the window.");
				if (!project.enabled) return OpenBox.doError("The box must be enabled in order to synchronize it.  Please click its checkbox on the left and try again.");
				
				OpenBox.apiPost('force_sync', { project_id: project.id, auto_error: 1 });
				
				// animate refresh icon thingy
				$('#refresh_thingy').removeClass('rotate').addClass('rotate');
				setTimeout( function() { $('#refresh_thingy').removeClass('rotate'); }, 500 );
			},
			
			viewLogFile: function() {
				// launch log file (txt) using OS X
				OpenBox.apiPost('open_log_file');
			},
			
			exportSettings: function() {
				// export all settings
				OpenBox.apiPost('export_settings', { auto_error: 1 });
			},
			
			importSettings: function() {
				// import all settings
				OpenBox.closeEditWindow();
				OpenBox.apiPost('import_settings', { auto_error: 1 }, function(resp) {
					// replace settings with new ones, and refresh adv page
					if (resp.Preferences) {
						prefs = resp.Preferences;
						$P('advanced').selectedIdx = -1;
						$P('advanced').onActivate();
					}
				});
			},
			
			onDeactivate: function() {
				
			}
		} // advanced page
	} // pages
	
};

function get_progress_bar(amount, width) {
	// get nice, OSX-like progress bar
	var extra_classes = ' normal';
	if (amount == -1) {
		extra_classes = ' indeterminate';
		amount = 1.0;
	}
	var html = '';
	html += '<div class="progress_container" style="width:'+width+'px">';
	html += '<div class="progress_bar'+extra_classes+'" style="width:'+Math.floor(width * amount)+'px"></div>';
	html += '</div>';
	return html;
}

function $P(id) {
	// get reference to page object
	if (!id) id = OpenBox.currentPageID;
	return OpenBox.pages[id];
}
