SWIFT ?= swift

.PHONY: help test lint project open clean

help:
	@echo "make test     - run the HRVKit test suite (works on macOS and Linux, no Xcode needed)"
	@echo "make project  - generate Nocturne.xcodeproj from project.yml (requires xcodegen)"
	@echo "make open     - generate the project and open it in Xcode"
	@echo "make clean    - remove build artefacts and the generated project"

test:
	$(SWIFT) test

project:
	@command -v xcodegen >/dev/null 2>&1 || { echo "xcodegen not found: brew install xcodegen"; exit 1; }
	xcodegen generate

open: project
	open Nocturne.xcodeproj

clean:
	rm -rf .build Nocturne.xcodeproj
