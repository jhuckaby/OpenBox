# Overview

OpenBox is a Mac OS X application which can synchronize folders to remote servers via [SSH](http://en.wikipedia.org/wiki/Secure_Shell) and [Rsync](http://en.wikipedia.org/wiki/Rsync), and keep them synchronized automatically and continuously in the background, similar to how [Dropbox](http://dropbox.com) behaves.  If you make changes to any file or folder, those changes are instantly detected and propagated to the server.  You can setup multiple boxes pointing to different servers, automatically copy URLs to your clipboard (if uploading to a web server for example), and receive notifications when sync operations complete.

To download the app, visit [OpenBox.io](http://openbox.io/).

# Features



# Languages

The OpenBox UI is written in HTML5 / JavaScript, and the background daemons are written in Perl.  The app is wrapped in a shell called [Cocui](https://github.com/rsms/cocui) which makes it behave like a real OS X app.

# Acknowlegements

OpenBox would not be possible without the following awesome tools / libraries:

* [Rsync](http://en.wikipedia.org/wiki/Rsync)
	* An incredible standard Unix / Mac command-line tool for synchronizing folders over the network.
* [Cocui - COCoa User Interface mockup](https://github.com/rsms/cocui)
	* This incredible framework allows you to make "native" Mac OS X apps using only HTML5 and JavaScript.
* [CocoaDialog](https://github.com/mstratman/cocoadialog)
	* This tool provides command-line access to Mac OS X native dialogs and more.
* [Mac::FSEvents](http://search.cpan.org/perldoc?Mac::FSEvents)
	* This is a Perl module which provides access to the Mac OS X FSEvents API, for instant notification of changed files.
* [IO::Pty::Easy](http://search.cpan.org/perldoc?IO::Pty::Easy)
	* This module allows a script to drive command-line tools such as Rsync and SSH, even providing passwords when prompted.
* [JSON::PP](http://search.cpan.org/perldoc?JSON::PP)
	* A pure Perl implementation of JSON encoding and decoding.
* [jQuery](http://jquery.com/)
	* The best JavaScript library ever invented.
* [HTML5 Boilerplate](http://html5boilerplate.com/)
	* Awesome framework for writing HTML5 apps.

And my thanks to the following artists / designers for use of their work:

* [Artua.com](http://www.artua.com/)
	* For their amazing [Mac OS X style Icon set](http://www.iconfinder.com/search/?q=iconset%3Amacosxstyle)
	* Three of these icons were used as the basis to create the OpenBox icon.
* [PixelPress Icons](http://www.pixelpressicons.com/)
	* For their [Whitespace Icon Collection](http://www.pixelpressicons.com/?page_id=118), used on the OpenBox.io website.
* [Apple Inc.](http://apple.com)
	* For their awesome background linen pattern.
* [Shockwave-Sound.com](http://www.shockwave-sound.com)
	* For their awesome stock sound effects (3 of which are used in OpenBox)

# Legal

**OpenBox v1.0**

Copyright (c) 2012 - 2014 Joseph Huckaby

Source Code released under the MIT License:

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

Please note that OpenBox relies on, and ships with, several 3rd party libraries, which have with their own license agreements.  The MIT License only covers the 1st party OpenBox code, written by Joseph Huckaby.
