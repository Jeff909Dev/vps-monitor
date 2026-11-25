.PHONY: build test app icon run install render status clean

build:
	swift build

test:
	swift test

app:
	./scripts/bundle.sh

icon:
	swift scripts/make-icon.swift

run: app
	open "../build/VPS Monitor.app"

install: app
	rm -rf "/Applications/VPS Monitor.app"
	ditto "../build/VPS Monitor.app" "/Applications/VPS Monitor.app"

# Every state of the popover and Settings, in English and Spanish, light and dark, into build/render/.
render: build
	./scripts/render-all.sh

# What the popover would say about the live server (read-only `vpsmon status`).
status: build
	.build/debug/vpsmon-mac status $(ARGS)

clean:
	rm -rf .build ../build
