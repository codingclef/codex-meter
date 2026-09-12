APP := dist/Codex Meter.app

.PHONY: build test install

build:
	mkdir -p "$(APP)/Contents/MacOS"
	cp Info.plist "$(APP)/Contents/Info.plist"
	clang -fobjc-arc -fmodules -fmodules-cache-path=/tmp/codex-meter-module-cache -framework Cocoa CodexMeter.m -o "$(APP)/Contents/MacOS/CodexMeter"

test: build
	"$(APP)/Contents/MacOS/CodexMeter" --self-test
	plutil -lint "$(APP)/Contents/Info.plist"

install: test
	ditto "$(APP)" "/Applications/Codex Meter.app"
	install -m 644 com.codingclef.codexmeter.plist "$(HOME)/Library/LaunchAgents/com.codingclef.codexmeter.plist"
