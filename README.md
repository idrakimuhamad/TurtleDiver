# TurtleDiver - macOS VPN Client

A native macOS application for managing VPN connections using openconnect, stoken, and vpn-slice.

## Features

- **Simple Interface**: Easy-to-use GUI for VPN connection management
- **Settings Management**: Store and manage VPN configuration settings
- **Connection Status**: Real-time connection status display
- **Debug Output**: Optional debug mode to view CLI command output
- **Tunneling Support**: Option to use vpn-slice for selective routing
- **Settings Persistence**: Settings are saved using macOS UserDefaults

## Prerequisites

Before using this application, ensure you have the following tools installed via Homebrew:

```bash
# Install required tools
brew install openconnect
brew install stoken
brew install vpn-slice
```

## Installation

1. Clone or download this project
2. Open `VPNConnect.xcodeproj` in Xcode
3. Build and run the project

## Configuration

### Initial Setup

1. Launch the application
2. Go to **TurtleDiver > Settings** (or press ⌘,)
3. Fill in the required VPN configuration:
   - **VPN Host**: Your VPN server hostname
   - **VPN ID**: Your VPN username/ID
   - **VPN Password**: Your VPN password
   - **Passcode**: Your RSA token passcode
   - **Slice URLs**: URLs/IP addresses to route through VPN (one per line)

### Loading Existing Configuration

The app can automatically load settings from your existing config file at `/Users/idraki/Documents/proxy/config.cfg` if it exists.

## Usage

### Connecting

1. Choose connection type:
   - **With tunneling**: Uses vpn-slice to route only specified URLs through VPN
   - **Without tunneling**: Routes all traffic through VPN
2. Click **Connect VPN**
3. You may be prompted for sudo password

### Disconnecting

Click **Disconnect** to terminate the VPN connection.

### Debug Mode

Enable debug mode in settings to view real-time CLI command output in the main window.

## Architecture

The application consists of several key components:

- **AppDelegate**: Main application lifecycle management
- **MainViewController**: Primary UI with connection controls and status display
- **SettingsManager**: Handles configuration persistence using UserDefaults
- **VPNManager**: Core VPN connection logic using Process to execute CLI commands
- **SettingsWindowController**: Settings configuration interface

## Security Notes

- VPN credentials are stored in macOS Keychain via UserDefaults
- The application requires sudo privileges for VPN connection
- All network traffic is handled through standard macOS networking APIs

## Troubleshooting

### Connection Issues

1. Verify all required tools are installed: `brew list openconnect stoken`
2. Check that vpn-slice is installed: `brew list | grep vpn-slice`
3. Ensure your VPN credentials are correct
4. Check debug output for specific error messages

### Token Generation Issues

If stoken fails to generate tokens:
1. Verify your RSA token is properly configured
2. Check that stoken is installed and accessible
3. Ensure your passcode is correct

### Network Issues

If VPN connects but traffic doesn't route properly:
1. Check slice URLs configuration
2. Verify network permissions in System Preferences
3. Review openconnect logs in debug mode

## Development

### Building from Source

1. Open the project in Xcode
2. Select your development team in project settings
3. Build and run (⌘R)

### Code Structure

```
VPNConnect/
├── AppDelegate.swift              # Application delegate
├── MainViewController.swift       # Main UI controller
├── VPNManager.swift              # VPN connection logic
├── SettingsManager.swift          # Settings management
├── SettingsWindowController.swift # Settings UI
├── Assets.xcassets               # App icons and assets
└── Info.plist                    # App configuration
```

## License

This project is provided as-is for educational and personal use.

## Support

For issues or questions, please check the troubleshooting section or review the debug output for specific error messages.
