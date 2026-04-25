APP_NAME := VoiceInput
APP_BUNDLE := $(APP_NAME).app
BUILD_DIR := $(shell swift build -c release --show-bin-path 2>/dev/null || echo .build/release)

# Version (single source of truth — bumped on release)
VERSION := 0.1.3

# Default: ad-hoc signing (works for local use; TCC re-prompts on each rebuild).
# To sign with your Apple Development identity without committing it to git,
# create a local-only file Makefile.local (gitignored) containing:
#   SIGN_ID := Apple Development: Your Name (TEAMID)
SIGN_ID ?= -

# Distribution signing identity (Developer ID Application).
# Override via Makefile.local with:
#   RELEASE_SIGN_ID := Developer ID Application: Your Name (TEAMID)
RELEASE_SIGN_ID ?= Developer ID Application: Hai Chang (5B858997A3)

# Notarization keychain profile (created by `xcrun notarytool store-credentials`)
NOTARY_PROFILE ?= VoiceInput-Notary

# Release artifact paths
DIST_DIR := dist
RELEASE_ZIP := $(DIST_DIR)/$(APP_NAME)-$(VERSION).zip

-include Makefile.local

.PHONY: build clean install run release-build notarize release-zip release verify-release dist-clean

build:
	swift build -c release
	$(eval BUILD_DIR := $(shell swift build -c release --show-bin-path))
	@if [ ! -f AppIcon.icns ]; then \
	  echo "Building AppIcon.icns..."; \
	  bash make-icns.sh; \
	fi
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	cp Info.plist $(APP_BUNDLE)/Contents/
	cp AppIcon.icns $(APP_BUNDLE)/Contents/Resources/
	codesign --force --options runtime --entitlements VoiceInput.entitlements --sign "$(SIGN_ID)" $(APP_BUNDLE)
	@echo "\n✅ Built $(APP_BUNDLE) (signed: $(SIGN_ID))"

run: build
	open $(APP_BUNDLE)

clean:
	swift package clean
	rm -rf $(APP_BUNDLE)

install: build
	rm -rf /Applications/$(APP_BUNDLE)
	cp -r $(APP_BUNDLE) /Applications/
	@echo "✅ Installed to /Applications/$(APP_BUNDLE)"

# ---------------------------------------------------------------------------
# Release pipeline (Developer ID + Notarization + Zip for Homebrew Cask)
# ---------------------------------------------------------------------------

# Build with Developer ID signing + hardened runtime (required for notarization).
release-build:
	@echo "🔨 Building release with Developer ID signing..."
	swift build -c release
	$(eval BUILD_DIR := $(shell swift build -c release --show-bin-path))
	@if [ ! -f AppIcon.icns ]; then bash make-icns.sh; fi
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	cp Info.plist $(APP_BUNDLE)/Contents/
	cp AppIcon.icns $(APP_BUNDLE)/Contents/Resources/
	codesign --force --deep --timestamp --options runtime \
	  --entitlements VoiceInput.entitlements \
	  --sign "$(RELEASE_SIGN_ID)" $(APP_BUNDLE)
	@echo "🔍 Verifying signature..."
	codesign --verify --deep --strict --verbose=2 $(APP_BUNDLE)
	@echo "\n✅ Release-built $(APP_BUNDLE) (signed: $(RELEASE_SIGN_ID))"

# Submit to Apple's notarization service, wait for result, then staple.
notarize: release-build
	@mkdir -p $(DIST_DIR)
	@echo "📦 Zipping for notarization..."
	ditto -c -k --keepParent $(APP_BUNDLE) $(DIST_DIR)/$(APP_NAME)-notary.zip
	@echo "☁️  Submitting to Apple notary service (this can take a few minutes)..."
	xcrun notarytool submit $(DIST_DIR)/$(APP_NAME)-notary.zip \
	  --keychain-profile "$(NOTARY_PROFILE)" \
	  --wait
	@echo "📎 Stapling notarization ticket to $(APP_BUNDLE)..."
	xcrun stapler staple $(APP_BUNDLE)
	xcrun stapler validate $(APP_BUNDLE)
	@rm -f $(DIST_DIR)/$(APP_NAME)-notary.zip
	@echo "\n✅ Notarized and stapled $(APP_BUNDLE)"

# Produce final user-facing zip (notarized + stapled .app inside).
release-zip: notarize
	@mkdir -p $(DIST_DIR)
	rm -f $(RELEASE_ZIP)
	ditto -c -k --keepParent $(APP_BUNDLE) $(RELEASE_ZIP)
	@echo "\n📦 Created $(RELEASE_ZIP)"
	@echo "SHA256:"
	@shasum -a 256 $(RELEASE_ZIP)

# One-shot: build + notarize + zip.
release: release-zip verify-release
	@echo "\n🚀 Release artifact ready: $(RELEASE_ZIP)"
	@echo "Next steps:"
	@echo "  1. git tag v$(VERSION) && git push --tags"
	@echo "  2. gh release create v$(VERSION) $(RELEASE_ZIP)"
	@echo "  3. Update Cask sha256 (see RELEASE_TODO.md Phase 5)"

# Independently verify the built/notarized .app passes Gatekeeper.
verify-release:
	@echo "🔍 codesign verify..."
	codesign --verify --deep --strict --verbose=2 $(APP_BUNDLE)
	@echo "🔍 spctl assess (Gatekeeper simulation)..."
	spctl --assess --type execute --verbose=2 $(APP_BUNDLE)
	@echo "🔍 stapler validate..."
	xcrun stapler validate $(APP_BUNDLE)
	@echo "✅ All verification checks passed"

dist-clean:
	rm -rf $(DIST_DIR)
