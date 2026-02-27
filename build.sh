#!/bin/bash

# Build script for TurtleDiver macOS app

echo "Building TurtleDiver..."

# Check if Xcode is installed
if ! command -v xcodebuild &> /dev/null; then
    echo "Error: Xcode is not installed. Please install Xcode from the App Store."
    exit 1
fi

# Check if required tools are installed
echo "Checking prerequisites..."

if ! command -v openconnect &> /dev/null; then
    echo "Warning: openconnect is not installed. Install with: brew install openconnect"
fi

if ! command -v stoken &> /dev/null; then
    echo "Warning: stoken is not installed. Install with: brew install stoken"
fi

# Check vpn-slice via Homebrew
if ! command -v brew &> /dev/null; then
    echo "Warning: Homebrew is not installed. Install with: https://brew.sh"
else
    if ! brew list --formula | grep -q "^vpn-slice$"; then
        echo "Warning: vpn-slice is not installed. Install with: brew install vpn-slice"
    fi
fi

# Clean build folder
if [ -d "build" ]; then
    echo "Cleaning previous build..."
    rm -rf build
fi

# Build the project
echo "Building project..."
xcodebuild -project VPNConnect.xcodeproj -scheme VPNConnect -configuration Release -derivedDataPath build build

if [ $? -eq 0 ]; then
    echo "Build successful!"
    echo "App location: build/Build/Products/Release/TurtleDiver.app"
    echo ""
    echo "To install the app:"
    echo "1. Copy TurtleDiver.app to your Applications folder"
    echo "2. Run the app from Applications"
    echo "3. You may need to allow the app in System Preferences > Security & Privacy"
else
    echo "Build failed. Please check the error messages above."
    exit 1
fi
