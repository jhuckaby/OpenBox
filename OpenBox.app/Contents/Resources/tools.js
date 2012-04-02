// OpenBox 1.0 Tools
// (c) 2012 Joseph Huckaby
// Released under the MIT License.

function dirname(path) {
	// return path excluding file at end (same as POSIX function of same name)
	return path.toString().replace(/\/$/, "").replace(/\/[^\/]+$/, "");
}

function basename(path) {
	// return filename, strip path (same as POSIX function of same name)
	return path.toString().replace(/\/$/, "").replace(/^(.*)\/([^\/]+)$/, "$2");
}

function trim(str) {
	// trim whitespace from beginning and end of string
	return str.toString().replace(/^\s+/, "").replace(/\s+$/, "");
}

function find_object(obj, criteria) {
	// walk array looking for nested object matching criteria object
	var criteria_length = 0;
	for (var a in criteria) criteria_length++;
	
	for (var a = 0; a < obj.length; a++) {
		var matches = 0;
		
		for (var b in criteria) {
			if (obj[a][b] && (obj[a][b] == criteria[b])) matches++;
			else if (obj[a]["_Attribs"] && obj[a]["_Attribs"][b] && (obj[a]["_Attribs"][b] == criteria[b])) matches++;
		}
		if (matches >= criteria_length) return obj[a];
	}
	return null;
}

function getInnerWindowSize(dom) {
	// get size of inner window
	// From: http://www.howtocreate.co.uk/tutorials/javascript/browserwindow
	if (!dom) dom = window;
	var myWidth = 0, myHeight = 0;
	
	if( typeof( dom.innerWidth ) == 'number' ) {
		// Non-IE
		myWidth = dom.innerWidth;
		myHeight = dom.innerHeight;
	}
	else if( dom.document.documentElement && ( dom.document.documentElement.clientWidth || dom.document.documentElement.clientHeight ) ) {
		// IE 6+ in 'standards compliant mode'
		myWidth = dom.document.documentElement.clientWidth;
		myHeight = dom.document.documentElement.clientHeight;
	}
	else if( dom.document.body && ( dom.document.body.clientWidth || dom.document.body.clientHeight ) ) {
		// IE 4 compatible
		myWidth = dom.document.body.clientWidth;
		myHeight = dom.document.body.clientHeight;
	}
	return { width: myWidth, height: myHeight };
}

var Dialog = {
	
	active: false,
	
	show: function(width, height, inner_html) {
		// show dialog
		var body = document.getElementsByTagName('body')[0];
		
		// build html for dialog
		var html = '';
		html += '<div id="dialog_main" style="width:'+width+'px; height:'+height+'px;">';
			html += inner_html;
		html += '</div>';
		
		var size = getInnerWindowSize();
		var x = Math.floor( (size.width / 2) - (width / 2) );
		var y = Math.floor( ((size.height / 2) - (height / 2)) * 0.75 );
		
		if ($('#dialog_overlay').length) {
			// $('#dialog_overlay').stop().fadeTo( 500, 0.75 );
		}
		else {
			var overlay = document.createElement('div');
			overlay.id = 'dialog_overlay';
			overlay.style.opacity = 1;
			body.appendChild(overlay);
			// $(overlay).fadeTo( 500, 0.75 );
		}
		
		if ($('#dialog_container').length) {
			$('#dialog_container').stop().css({
				left: '' + x + 'px',
				top: '' + y + 'px'
			}).html(html); // .fadeIn( 250 );
		}
		else {
			var container = document.createElement('div');
			container.id = 'dialog_container';
			container.style.opacity = 1;
			container.style.left = '' + x + 'px';
			container.style.top = '' + y + 'px';
			container.innerHTML = html;
			body.appendChild(container);
			// $(container).fadeTo( 250, 1.0 );
		}
		
		this.active = true;
	},
	
	hide: function() {
		// hide dialog
		if (this.active) {
			// $('#dialog_container').stop().fadeOut( 250, function() { $(this).remove(); } );
			// $('#dialog_overlay').stop().fadeOut( 500, function() { $(this).remove(); } );
			$('#dialog_container, #dialog_overlay').remove();
			this.active = false;
		}
	},
	
	showProgress: function(msg) {
		// show simple progress dialog (unspecified duration)
		var html = '';
		html += '<table width="300" height="120" cellspacing="0" cellpadding="0"><tr><td width="300" height="120" align="center" valign="center">';
		html += '<img src="images/loading.gif" width="32" height="32"/><br/><br/>';
		html += '<span class="label" style="padding-top:5px">' + msg + '</span>';
		html += '</td></tr></table>';
		this.show( 300, 120, html );
	}
	
};

var months = [
	[ 1, 'January' ], [ 2, 'February' ], [ 3, 'March' ], [ 4, 'April' ],
	[ 5, 'May' ], [ 6, 'June' ], [ 7, 'July' ], [ 8, 'August' ],
	[ 9, 'September' ], [ 10, 'October' ], [ 11, 'November' ],
	[ 12, 'December' ]
];

var day_names = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 
	'Thursday', 'Friday', 'Saturday'];

function get_date_args(epoch) {
	// return hash containing year, mon, mday, hour, min, sec
	// given epoch seconds
	var date = new Date( epoch * 1000 );
	var args = {
		year: date.getFullYear(),
		mon: date.getMonth() + 1,
		mday: date.getDate(),
		hour: date.getHours(),
		min: date.getMinutes(),
		sec: date.getSeconds(),
		msec: date.getMilliseconds()
	};

	args.yyyy = args.year;
	if (args.mon < 10) args.mm = "0" + args.mon; else args.mm = args.mon;
	if (args.mday < 10) args.dd = "0" + args.mday; else args.dd = args.mday;
	if (args.hour < 10) args.hh = "0" + args.hour; else args.hh = args.hour;
	if (args.min < 10) args.mi = "0" + args.min; else args.mi = args.min;
	if (args.sec < 10) args.ss = "0" + args.sec; else args.ss = args.sec;

	if (args.hour >= 12) {
		args.ampm = 'pm';
		args.hour12 = args.hour - 12;
		if (!args.hour12) args.hour12 = 12;
	}
	else {
		args.ampm = 'am';
		args.hour12 = args.hour;
		if (!args.hour12) args.hour12 = 12;
	}
	return args;
}

function get_nice_date(epoch, abbrev) {
	var dargs = get_date_args(epoch);
	var month = months[dargs.mon - 1][1];
	if (abbrev) month = month.substring(0, 3);
	return month + ' ' + dargs.mday + ', ' + dargs.year;
}

function get_nice_time(epoch, secs) {
	// return time in HH12:MM format
	var dargs = get_date_args(epoch);
	if (dargs.min < 10) dargs.min = '0' + dargs.min;
	if (dargs.sec < 10) dargs.sec = '0' + dargs.sec;
	var output = dargs.hour12 + ':' + dargs.min;
	if (secs) output += ':' + dargs.sec;
	output += ' ' + dargs.ampm.toUpperCase();
	return output;
}

function get_midnight(date) {
	// return epoch of nearest midnight in past (local time)
	var midnight = parseInt( date.getTime() / 1000, 10 );

	midnight -= (date.getHours() * 3600);
	midnight -= (date.getMinutes() * 60);
	midnight -= date.getSeconds();

	return midnight;
}

function get_relative_date_html(epoch, show_time) {
	// convert epoch to short date string
	epoch = Math.floor(epoch);
	var mydate = new Date( epoch * 1000 );
	
	var now = new Date();
	var now_epoch = parseInt( now.getTime() / 1000, 10 );

	// relative date display
	var full_date_string = mydate.toLocaleString();
	var html = '<span title="'+full_date_string+'">';

	// get midnight of each
	var mydate_midnight = get_midnight( mydate );
	var now_midnight = get_midnight( now );

	if (mydate_midnight > now_midnight) {
		// date in future
		html += get_nice_date(epoch, true);
	}
	else if (mydate_midnight == now_midnight) {
		// today
		if (show_time) {
			if (now_epoch - epoch < 1) {
				html += 'Now';
			}
			else if (now_epoch - epoch < 60) {
				html += 'A Moment Ago';
			}
			else if (now_epoch - epoch < 3600) {
				// less than 1 hour ago
				var min = parseInt( (now_epoch - epoch) / 60, 10 );
				html += min + ' Minute';
				if (min != 1) html += 's';
				html += ' Ago';
			}
			else if (now_epoch - epoch <= 12 * 3600) {
				// 12 hours or less prior
				var hr = parseInt( (now_epoch - epoch) / 3600, 10 );
				html += hr + ' Hour';
				if (hr != 1) html += 's';
				html += ' Ago';
			}
			else {
				// more than 12 hours ago, but still today
				html += get_nice_time(epoch, false);
			}
		}
		else html += 'Today';
	}
	else if (now_midnight - mydate_midnight == 86400) {
		// yesterday
		html += 'Yesterday';
		if (show_time) html += ', ' + get_nice_time(epoch, false);
	}
	else if ((now_midnight - mydate_midnight < 86400 * 7) && (mydate.getDay() < now.getDay())) {
		// this week
		html += day_names[ mydate.getDay() ];
		if (show_time) html += ', ' + get_nice_time(epoch, false);
	}
	else if ((mydate.getMonth() == now.getMonth()) && (mydate.getFullYear() == now.getFullYear())) {
		// this month
		var mydate_sunday = mydate_midnight - (mydate.getDay() * 86400);
		var now_sunday = now_midnight - (now.getDay() * 86400);

		if (now_sunday - mydate_sunday == 86400 * 7) {
			// last week
			html += 'Last ' + day_names[ mydate.getDay() ];
		}
		else {
			// older than a week
			html += get_nice_date(epoch, true);
		}
	}
	else {
		// older than a month
		html += get_nice_date(epoch, true);
	}

	html += '</span>';
	return html;
}

function get_text_from_seconds(sec, abbrev, no_secondary) {
	// convert raw seconds to human-readable relative time
	var neg = '';
	sec = parseInt(sec, 10);
	if (sec<0) { sec =- sec; neg = '-'; }
	
	var p_text = abbrev ? "sec" : "second";
	var p_amt = sec;
	var s_text = "";
	var s_amt = 0;
	
	if (sec > 59) {
		var min = parseInt(sec / 60, 10);
		sec = sec % 60; 
		s_text = abbrev ? "sec" : "second"; 
		s_amt = sec; 
		p_text = abbrev ? "min" : "minute"; 
		p_amt = min;
		
		if (min > 59) {
			var hour = parseInt(min / 60, 10);
			min = min % 60; 
			s_text = abbrev ? "min" : "minute"; 
			s_amt = min; 
			p_text = abbrev ? "hr" : "hour"; 
			p_amt = hour;
			
			if (hour > 23) {
				var day = parseInt(hour / 24, 10);
				hour = hour % 24; 
				s_text = abbrev ? "hr" : "hour"; 
				s_amt = hour; 
				p_text = "day"; 
				p_amt = day;
				
				if (day > 29) {
					var month = parseInt(day / 30, 10);
					day = day % 30; 
					s_text = "day"; 
					s_amt = day; 
					p_text = abbrev ? "mon" : "month"; 
					p_amt = month;
				} // day>29
			} // hour>23
		} // min>59
	} // sec>59
	
	var text = p_amt + "&nbsp;" + p_text;
	if ((p_amt != 1) && !abbrev) text += "s";
	if (s_amt && !no_secondary) {
		text += ", " + s_amt + "&nbsp;" + s_text;
		if ((s_amt != 1) && !abbrev) text += "s";
	}
	
	return(neg + text);
}

function get_nice_remaining_time(epoch_start, epoch_now, counter, counter_max, abbrev, no_secondary) {
	// estimate remaining time given starting epoch, a counter and the 
	// counter maximum (i.e. percent and 100 would work)
	// return in english-readable format
	
	if (counter == counter_max) return 'Complete';
	if (counter == 0) return 'n/a';
	
	var sec_remain = parseInt(((counter_max - counter) * (epoch_now - epoch_start)) / counter, 10);
	
	return get_text_from_seconds( sec_remain, abbrev, no_secondary );
}

function get_text_from_bytes(bytes) {
	// convert raw bytes to english-readable format
	bytes = Math.floor(bytes);
	if (bytes >= 1024) {
		bytes = parseInt( (bytes / 1024) * 10, 10 ) / 10;
		if (bytes >= 1024) {
			bytes = parseInt( (bytes / 1024) * 10, 10 ) / 10;
			if (bytes >= 1024) {
				bytes = parseInt( (bytes / 1024) * 10, 10 ) / 10;
				if (bytes >= 1024) {
					bytes = parseInt( (bytes / 1024) * 10, 10 ) / 10;
					if (bytes >= 1024) {
						bytes = parseInt( (bytes / 1024) * 10, 10 ) / 10;
						return bytes + ' PB';
					} 
					else return bytes + ' TB';
				} 
				else return bytes + ' GB';
			} 
			else return bytes + ' MB';
		}
		else return bytes + ' K';
	}
	else return bytes + ' bytes';
}

function commify(number) {
	// add commas to integer, like 1,234,567
	if (!number) number = 0;

	number = '' + number;
	if (number.length > 3) {
		var mod = number.length % 3;
		var output = (mod > 0 ? (number.substring(0,mod)) : '');
		for (i=0 ; i < Math.floor(number.length / 3); i++) {
			if ((mod == 0) && (i == 0))
				output += number.substring(mod+ 3 * i, mod + 3 * i + 3);
			else
				output+= ',' + number.substring(mod + 3 * i, mod + 3 * i + 3);
		}
		return (output);
	}
	else return number;
}

function time_now() {
	// return the Epoch seconds for like right now
	var now = new Date();
	return parseInt( now.getTime() / 1000, 10 );
}

function hires_time_now() {
	// return the Epoch seconds for like right now
	var now = new Date();
	return ( now.getTime() / 1000 );
}
