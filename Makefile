APP_NAME := VoiceInput
APP_BUNDLE := $(APP_NAME).app
BUILD_DIR := $(shell swift build -c release --show-bin-path 2>/dev/null || echo .build/release)
# Default: ad-hoc signing (works for local use; TCC re-prompts on each rebuild).
# To sign with your Apple Development identity without committing it to git,
# create a local-only file Makefile.local (gitignored) containing:
#   SIGN_ID := Apple Development: Your Name (TEAMID)
SIGN_ID ?= -

-include Makefile.local

.PHONY: build clean install run

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
