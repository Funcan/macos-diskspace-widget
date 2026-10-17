.PHONY: build format test install uninstall clean

build:
	swift build

format:
	swiftformat .

test:
	@if [ -d Tests ]; then swift test; else echo "No Tests directory, skipping tests."; fi

install:
	./scripts/install-launchagent.sh

uninstall:
	./scripts/uninstall-launchagent.sh

clean:
	swift package clean
