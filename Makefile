BUNDLE = noti.app
ICON_SRC = huh.png
ICONSET = AppIcon.iconset
ICNS = AppIcon.icns
DIST_DIR = dist
PKG_ID = com.noti.app
PKG_VERSION = $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist 2>/dev/null || echo 1.0)
PKG = $(DIST_DIR)/noti-$(PKG_VERSION).pkg

.PHONY: build app run install pkg bump-version clean

build:
	swift build -c release

$(ICNS): $(ICON_SRC)
	rm -rf $(ICONSET)
	mkdir -p $(ICONSET)
	sips -z 16 16     $(ICON_SRC) --out $(ICONSET)/icon_16x16.png
	sips -z 32 32     $(ICON_SRC) --out $(ICONSET)/icon_16x16@2x.png
	sips -z 32 32     $(ICON_SRC) --out $(ICONSET)/icon_32x32.png
	sips -z 64 64     $(ICON_SRC) --out $(ICONSET)/icon_32x32@2x.png
	sips -z 128 128   $(ICON_SRC) --out $(ICONSET)/icon_128x128.png
	sips -z 256 256   $(ICON_SRC) --out $(ICONSET)/icon_128x128@2x.png
	sips -z 256 256   $(ICON_SRC) --out $(ICONSET)/icon_256x256.png
	sips -z 512 512   $(ICON_SRC) --out $(ICONSET)/icon_256x256@2x.png
	sips -z 512 512   $(ICON_SRC) --out $(ICONSET)/icon_512x512.png
	sips -z 1024 1024 $(ICON_SRC) --out $(ICONSET)/icon_512x512@2x.png
	iconutil -c icns $(ICONSET) -o $(ICNS)
	rm -rf $(ICONSET)

app: build $(ICNS)
	mkdir -p $(BUNDLE)/Contents/MacOS
	mkdir -p $(BUNDLE)/Contents/Resources
	cp "$$(swift build -c release --show-bin-path)/noti" $(BUNDLE)/Contents/MacOS/
	cp Info.plist $(BUNDLE)/Contents/
	cp $(ICNS) $(BUNDLE)/Contents/Resources/
	cp $(ICON_SRC) $(BUNDLE)/Contents/Resources/
	codesign --sign - --force --deep $(BUNDLE)

run: app
	open -n $(BUNDLE)

install: app
	cp -r $(BUNDLE) ~/Applications/

pkg: app
	mkdir -p $(DIST_DIR)
	rm -f $(PKG)
	pkgbuild \
		--component $(BUNDLE) \
		--install-location /Applications \
		--identifier $(PKG_ID) \
		--version $(PKG_VERSION) \
		$(PKG)
	@echo "Created $(PKG)"

bump-version:
	./scripts/bump-version.sh $(PART)

clean:
	rm -rf $(BUNDLE) .build $(DIST_DIR)
