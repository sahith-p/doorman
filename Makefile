.PHONY: build test e2e snapshots brand app install package demo probe

build:
	swift build

test:
	swift test

# Real Chrome, the real extension, the real MCP server, and the demo site.
e2e: build
	.build/debug/doorman-e2e

# Does Apple's helper answer on this Mac? Shows no PIN and reads no password.
probe: build
	.build/debug/doorman-e2e --apple-probe

snapshots: build
	.build/debug/doorman-snapshots

# The icon, the logos and the extension's images, all drawn from scripts/make-brand.py.
brand:
	python3 -I scripts/make-brand.py

app:
	scripts/build-app.sh

# Builds, copies to ~/Applications, and opens it.
install: app
	scripts/install.sh

# A universal disk image to hand to someone else, in dist/.
package:
	scripts/package.sh

# The pretend website for trying everything with nothing real at stake.
demo:
	node demo/server.mjs
