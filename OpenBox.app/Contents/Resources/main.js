// Load index.html in a regular window and display it
var size = { width: 600, height: 500 };

var win = App.createWindow({
  uri: 'index.html',
	// name: 'main',
  rect: { 
	origin: {x: Math.floor((screen.width / 2) - (size.width / 2)) , y: Math.floor((screen.height / 2) - (size.height / 2)) + 50},
	size: size
  },
  style: { 
	closable: false,
	textured: false,
	resizable: false
  }
});
win.makeKeyAndOrderFront();

// Alternative minimal example of opening a window
/*App.createWindow('index.html').makeKeyAndOrderFront();
*/

/*
 Important information:
 Loading and executing content directly from the Internets is DANGEROUS.
   App.createWindow('http://evil.site/exploit-cocui-relaxness') == epic fail
 This is because Cocui employs relaxed security rules, like unrestricted XHR and
 to some extent access to the userland part of the operating system (I/O etc).
 Load remote content at your own risk -- you have been warned.
*/

// Example of a fullscreen window (quits after 4 seconds)
/*App.createWindow({ uri: 'index.html', fullscreen: true }).makeKeyAndOrderFront();
setTimeout(function(){ App.terminate() }, 4000);
*/

// Alternative example of a fullscreen window (exits fullscreen after 4 seconds)
/*var win = App.createWindow({uri: 'index.html'}); // add style:{borderless:true} to remove ui chrome
win.makeKeyAndOrderFront();
win.fullscreen = true;
setTimeout(function(){ win.fullscreen = false }, 4000);
*/

// Example of encoding and decoding JSON
/*var s = App.encodeJSON({uri: 'index.html', moset: {0:1,1:2,9:3,4:undefined,98:56}});
console.log(s);
var o = App.decodeJSON(s);
console.log(o.uri);
*/
