APP_NAME   := ArchScan
CONFIG     ?= release
APP_BUNDLE := dist/$(APP_NAME).app

# Without Xcode, SwiftPM doesn't find the Swift Testing macro plugin by itself.
TESTING_PLUGINS := $(shell xcode-select -p)/usr/lib/swift/host/plugins/testing

.PHONY: build test app run clean

# Compile the executable with SwiftPM.
build:
	swift build -c $(CONFIG)

test:
	swift test -Xswiftc -plugin-path -Xswiftc "$(TESTING_PLUGINS)"

# Wrap the executable in a .app bundle and ad-hoc sign it.
app: build
	rm -rf "$(APP_BUNDLE)"
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	cp "$$(swift build -c $(CONFIG) --show-bin-path)/$(APP_NAME)" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	cp Support/Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	codesign --force --sign - "$(APP_BUNDLE)"

run: app
	open "$(APP_BUNDLE)"

clean:
	swift package clean
	rm -rf dist
