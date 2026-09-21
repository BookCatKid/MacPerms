APP      := MacPerms
BUILD    := build
BUNDLE   := $(BUILD)/$(APP).app
MACOS    := $(BUNDLE)/Contents/MacOS
RES      := $(BUNDLE)/Contents/Resources
SOURCES  := $(wildcard Sources/*.swift)
SDK      := /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
IDENTITY := dev.macperms.app

.PHONY: all run clean

all: $(BUNDLE)

$(BUNDLE): $(SOURCES) Helper/main.swift Info.plist Resources/tcc-system-write.sh
	@mkdir -p "$(MACOS)" "$(RES)"
	swiftc -O -o "$(MACOS)/$(APP)" $(SOURCES) \
		-target arm64-apple-macosx15.0 -sdk $(SDK)
	swiftc -O -o "$(RES)/needt" Helper/main.swift Sources/NEPlist.swift \
		-target arm64-apple-macosx15.0 -sdk $(SDK)
	@cp Info.plist "$(BUNDLE)/Contents/Info.plist"
	@cp Resources/tcc-system-write.sh "$(RES)/tcc-system-write.sh"
	@chmod +x "$(RES)/tcc-system-write.sh"
	codesign -s - --identifier $(IDENTITY) -f "$(BUNDLE)"
	@echo "Built $(BUNDLE)"

run: all
	open "$(BUNDLE)"

clean:
	rm -rf "$(BUILD)"
