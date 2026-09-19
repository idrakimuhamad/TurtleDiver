TurtleDiver @VERSION@
=====================

INSTALL
-------
1. Put TurtleDiver.app in your Applications folder. If you opened the disk
   image, drag it onto the Applications shortcut in the window.
2. Open it from Applications. It lives in the menu bar (the turtle).

If macOS says the app "cannot be opened because the developer cannot be
verified", the copy you have was not notarized. Either use the notarized disk
image from the release page, or open it once by hand:

    Right-click TurtleDiver.app > Open

or, on macOS 15 and later, allow it in System Settings > Privacy & Security.
After that first launch macOS remembers the app and double-click works.

DEPENDENCIES
------------
TurtleDiver drives three command-line tools. It does NOT ship them: they are
separate projects with their own updates and licences (LGPL-2.1 / GPL-3.0).
Install them with Homebrew:

    brew install openconnect stoken vpn-slice

Check what TurtleDiver can see:

    openconnect --version
    stoken --version
    vpn-slice --version

The app looks for them in /opt/homebrew/bin, /usr/local/bin, /usr/bin and
/bin.

WHAT IT NEEDS SUDO FOR
----------------------
openconnect and vpn-slice configure the utun interface and the routing table,
so they run as root. The app asks for your administrator password once and
keeps it in the login Keychain; it is passed to sudo on stdin, never on a
command line. Setting a system proxy also needs it.

THE TUNNEL AGENT
----------------
If you installed TurtleDiver from the package, it also installed a small
helper (a few hundred kilobytes) at:

    /usr/local/libexec/turtlediver-agent

It exists so that disconnecting does not have to ask for your password again.
The app starts it once when you connect — that is the one moment macOS asks
you to approve — and it ends the tunnel later on its own, because it is
already running as root. It starts nothing but openconnect, it can be told to
do exactly one thing (stop the tunnel it started), and it exits when the app
exits.

It is owned by root and cannot be replaced by your user account, and the app
verifies its signature before using it. If it is not installed — for example
if you dragged the app out of the disk image instead of using the package —
everything still works, except that disconnecting may ask for your password.
You can install or remove it yourself:

    ./packaging/install-agent.sh
    ./packaging/install-agent.sh --uninstall

WHERE THINGS LIVE
-----------------
    ~/Library/Application Support/TurtleDiver/Profiles/   your profiles
    ~/Library/Application Support/TurtleDiver/run/        openconnect.pid
    ~/Library/Logs/TurtleDiver/vpn.log                    connection log
    ~/Library/Logs/TurtleDiver/launch.log                 launch log

Credentials live in the login Keychain, never in a preferences file.
