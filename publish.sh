#!/bin/bash

APP_NAME="TurtleDiver"
PROJECT_NAME="VPNConnect"
SCHEME="VPNConnect"
BUILD_DIR="build"
DIST_DIR="dist"
APP_PATH="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "1.0")

# Text for Gatekeeper warning
GATEKEEPER_NOTE="IMPORTANT INSTALLATION NOTE:

1. GATEKEEPER / SECURITY
If you see a warning that this app 'cannot be opened because the developer cannot be verified':
   - Drag the app to your Applications folder.
   - Right-click (or Control-click) the app icon.
   - Select 'Open' from the menu.
   - Click 'Open' in the dialog box.
   
   Alternatively, go to System Settings > Privacy & Security, find the block message, and click 'Open Anyway'.

2. DEPENDENCIES
This application requires the following command-line tools to be installed via Homebrew:
   - openconnect
   - stoken
   - vpn-slice

If you haven't installed them, please run:
   brew install openconnect stoken vpn-slice"

function print_status() {
    echo "=> $1"
}

function check_tools() {
    if ! command -v xcodebuild &> /dev/null; then
        echo "Error: xcodebuild not found. Install Xcode."
        exit 1
    fi
}

function build_app() {
    print_status "Building $APP_NAME..."
    
    # Clean and build
    rm -rf "$BUILD_DIR"
    xcodebuild -project "$PROJECT_NAME.xcodeproj" \
               -scheme "$SCHEME" \
               -configuration Release \
               -derivedDataPath "$BUILD_DIR" \
               build
               
    if [ $? -ne 0 ]; then
        echo "Error: Build failed."
        exit 1
    fi
    
    # Verify app exists
    if [ ! -d "$APP_PATH" ]; then
        echo "Error: App not found at $APP_PATH"
        exit 1
    fi
    
    # Update VERSION after build
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "1.0")
    print_status "Build complete. Version: $VERSION"
}

function create_dmg() {
    print_status "Creating DMG installer..."
    
    local dmg_name="$APP_NAME-$VERSION.dmg"
    local dmg_path="$DIST_DIR/$dmg_name"
    local stage_dir="$BUILD_DIR/dmg_stage"
    
    # Prepare staging area
    rm -rf "$stage_dir"
    mkdir -p "$stage_dir"
    
    # Copy app
    cp -R "$APP_PATH" "$stage_dir/"
    
    # Create symlink to Applications
    ln -s /Applications "$stage_dir/Applications"
    
    # Create ReadMe file
    echo "$GATEKEEPER_NOTE" > "$stage_dir/READ_ME_FIRST.txt"
    
    # Create DMG
    rm -f "$dmg_path"
    hdiutil create -volname "$APP_NAME" \
                   -srcfolder "$stage_dir" \
                   -ov -format UDZO \
                   "$dmg_path"
                   
    print_status "DMG created at: $dmg_path"
}

function create_pkg() {
    echo "=> Creating PKG installer..."
    
    local version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
    local pkg_name="${APP_NAME}-${version}.pkg"
    local pkg_output="$DIST_DIR/$pkg_name"
    local component_pkg="$BUILD_DIR/${APP_NAME}.component.pkg"
    local dist_xml="$BUILD_DIR/distribution.xml"
    local readme_path="$BUILD_DIR/README_INSTALL.txt"

    # Create the readme file
    echo "$GATEKEEPER_NOTE" > "$readme_path"

    # 1. Build component package
    pkgbuild --root "$APP_PATH" \
             --install-location "/Applications/$APP_NAME.app" \
             --identifier "com.local.$APP_NAME" \
             --version "$version" \
             "$component_pkg"

    # 2. Synthesize distribution
    productbuild --synthesize \
                 --package "$component_pkg" \
                 "$dist_xml"

    # 3. Inject readme into distribution xml
    # We insert it after the opening <installer-gui-script ...> tag
    # Using perl for safer multiline replacement or sed
    sed -i '' 's|<installer-gui-script minSpecVersion="1">|<installer-gui-script minSpecVersion="1">\n    <readme file="README_INSTALL.txt"/>|' "$dist_xml"
    # Also ensure title is set
    sed -i '' "s|<installer-gui-script minSpecVersion=\"1\">|<installer-gui-script minSpecVersion=\"1\">\n    <title>$APP_NAME $version</title>|" "$dist_xml"

    # 4. Build final product package
    # We need to provide the directory containing the readme as --resources or just make sure it's found.
    # --resources dir: "The path to a directory containing the resources for the installer (e.g. ReadMe, License, etc.)"
    # We put README_INSTALL.txt in BUILD_DIR, so we use BUILD_DIR as resources path.
    
    productbuild --distribution "$dist_xml" \
                 --package-path "$BUILD_DIR" \
                 --resources "$BUILD_DIR" \
                 --sign "Sign to Run Locally" \
                 "$pkg_output" || \
    productbuild --distribution "$dist_xml" \
                 --package-path "$BUILD_DIR" \
                 --resources "$BUILD_DIR" \
                 "$pkg_output"

    if [ -f "$pkg_output" ]; then
        echo "=> PKG created at: $pkg_output"
    else
        echo "=> Error creating PKG"
    fi
}

# Main execution
mkdir -p "$DIST_DIR"

check_tools
build_app
create_dmg
create_pkg

print_status "All done! Installers are in the '$DIST_DIR' directory."
