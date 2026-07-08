PREFIX ?= /usr/local

build:
	swift build -c release

test:
	swift test

install: build
	install -d $(PREFIX)/bin
	install .build/release/simlease $(PREFIX)/bin/simlease

app:
	./scripts/make-app.sh

.PHONY: build test install app
