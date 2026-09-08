SWIFT ?= swift

.PHONY: help test test-kit test-server project open clean

help:
	@echo "make test     - run everything: HRVKit plus the sync server"
	@echo "make test-kit - run the HRVKit test suite (macOS or Linux, no Xcode needed)"
	@echo "make test-server - run the sync server test suite"
	@echo "make project  - generate Nocturne.xcodeproj from project.yml (requires xcodegen)"
	@echo "make open     - generate the project and open it in Xcode"
	@echo "make clean    - remove build artefacts and the generated project"

test: test-kit test-server

test-kit:
	$(SWIFT) test

test-server:
	$(MAKE) -C server test

project:
	@command -v xcodegen >/dev/null 2>&1 || { echo "xcodegen not found: brew install xcodegen"; exit 1; }
	xcodegen generate

open: project
	open Nocturne.xcodeproj

clean:
	rm -rf .build Nocturne.xcodeproj
