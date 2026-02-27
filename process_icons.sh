#!/bin/bash

# Define paths
APP_ICON_SRC="app-icon.png"
MENU_ICON_SRC="icon-menu-bar.png"
ASSETS_DIR="VPNConnect/Assets.xcassets"
APP_ICON_SET="$ASSETS_DIR/AppIcon.appiconset"
MENU_ICON_SET="$ASSETS_DIR/MenuBarIcon.imageset"

# Create directories
mkdir -p "$APP_ICON_SET"
mkdir -p "$MENU_ICON_SET"

# --- Process App Icon ---
echo "Processing App Icon..."

# Resize to standard sizes (force square 1024x1024 first)
# Note: sips -z height width
sips -z 16 16 "$APP_ICON_SRC" --out "$APP_ICON_SET/icon_16x16.png"
sips -z 32 32 "$APP_ICON_SRC" --out "$APP_ICON_SET/icon_16x16@2x.png"
sips -z 32 32 "$APP_ICON_SRC" --out "$APP_ICON_SET/icon_32x32.png"
sips -z 64 64 "$APP_ICON_SRC" --out "$APP_ICON_SET/icon_32x32@2x.png"
sips -z 128 128 "$APP_ICON_SRC" --out "$APP_ICON_SET/icon_128x128.png"
sips -z 256 256 "$APP_ICON_SRC" --out "$APP_ICON_SET/icon_128x128@2x.png"
sips -z 256 256 "$APP_ICON_SRC" --out "$APP_ICON_SET/icon_256x256.png"
sips -z 512 512 "$APP_ICON_SRC" --out "$APP_ICON_SET/icon_256x256@2x.png"
sips -z 512 512 "$APP_ICON_SRC" --out "$APP_ICON_SET/icon_512x512.png"
sips -z 1024 1024 "$APP_ICON_SRC" --out "$APP_ICON_SET/icon_512x512@2x.png"

# Create Contents.json for AppIcon
cat > "$APP_ICON_SET/Contents.json" <<EOF
{
  "images" : [
    {
      "size" : "16x16",
      "idiom" : "mac",
      "filename" : "icon_16x16.png",
      "scale" : "1x"
    },
    {
      "size" : "16x16",
      "idiom" : "mac",
      "filename" : "icon_16x16@2x.png",
      "scale" : "2x"
    },
    {
      "size" : "32x32",
      "idiom" : "mac",
      "filename" : "icon_32x32.png",
      "scale" : "1x"
    },
    {
      "size" : "32x32",
      "idiom" : "mac",
      "filename" : "icon_32x32@2x.png",
      "scale" : "2x"
    },
    {
      "size" : "128x128",
      "idiom" : "mac",
      "filename" : "icon_128x128.png",
      "scale" : "1x"
    },
    {
      "size" : "128x128",
      "idiom" : "mac",
      "filename" : "icon_128x128@2x.png",
      "scale" : "2x"
    },
    {
      "size" : "256x256",
      "idiom" : "mac",
      "filename" : "icon_256x256.png",
      "scale" : "1x"
    },
    {
      "size" : "256x256",
      "idiom" : "mac",
      "filename" : "icon_256x256@2x.png",
      "scale" : "2x"
    },
    {
      "size" : "512x512",
      "idiom" : "mac",
      "filename" : "icon_512x512.png",
      "scale" : "1x"
    },
    {
      "size" : "512x512",
      "idiom" : "mac",
      "filename" : "icon_512x512@2x.png",
      "scale" : "2x"
    }
  ],
  "info" : {
    "version" : 1,
    "author" : "xcode"
  }
}
EOF

# --- Process Menu Bar Icon ---
echo "Processing Menu Bar Icon..."

# Resize to 18x18 (1x) and 36x36 (2x) and 54x54 (3x)
sips -z 18 18 "$MENU_ICON_SRC" --out "$MENU_ICON_SET/MenuBarIcon_1x.png"
sips -z 36 36 "$MENU_ICON_SRC" --out "$MENU_ICON_SET/MenuBarIcon_2x.png"
sips -z 54 54 "$MENU_ICON_SRC" --out "$MENU_ICON_SET/MenuBarIcon_3x.png"

# Create Contents.json for MenuBarIcon (Template Mode)
cat > "$MENU_ICON_SET/Contents.json" <<EOF
{
  "images" : [
    {
      "size" : "18x18",
      "idiom" : "mac",
      "filename" : "MenuBarIcon_1x.png",
      "scale" : "1x"
    },
    {
      "size" : "18x18",
      "idiom" : "mac",
      "filename" : "MenuBarIcon_2x.png",
      "scale" : "2x"
    },
    {
      "size" : "18x18",
      "idiom" : "mac",
      "filename" : "MenuBarIcon_3x.png",
      "scale" : "3x"
    }
  ],
  "info" : {
    "version" : 1,
    "author" : "xcode"
  },
  "properties" : {
    "template-rendering-intent" : "template"
  }
}
EOF

echo "Done."
