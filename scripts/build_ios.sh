#!/bin/bash

# iOS Build Script for Codemagic
# This script addresses common Codemagic iOS build issues

set -e

echo "🚀 Starting iOS build process..."

# Clean everything
echo "🧹 Cleaning previous builds..."
flutter clean
rm -rf ios/Pods
rm -rf ios/Podfile.lock
rm -rf build/

# Get dependencies
echo "📦 Getting Flutter dependencies..."
flutter pub get
flutter pub deps

# Install CocoaPods with specific version
echo "🍫 Installing CocoaPods..."
cd ios
pod repo update
pod install --verbose
cd ..

# Build for simulator
echo "🔨 Building for iOS Simulator..."
flutter build ios --simulator --debug --verbose

# Verify build
echo "✅ Verifying build..."
if [ -d "build/ios/iphonesimulator/Runner.app" ]; then
    echo "✅ Runner.app created successfully"
    
    # Check Flutter framework
    if [ -d "build/ios/iphonesimulator/Runner.app/Frameworks/Flutter.framework" ]; then
        echo "✅ Flutter framework embedded"
    else
        echo "❌ Flutter framework missing!"
        exit 1
    fi
    
    # Check app size
    APP_SIZE=$(du -sh build/ios/iphonesimulator/Runner.app | cut -f1)
    echo "📱 App size: $APP_SIZE"
    
    # List contents
    echo "📋 App contents:"
    ls -la build/ios/iphonesimulator/Runner.app/
    
else
    echo "❌ Runner.app not found!"
    exit 1
fi

echo "🎉 Build completed successfully!"
