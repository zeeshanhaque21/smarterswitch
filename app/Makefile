.PHONY: analyze test build release clean

# Get current version from pubspec.yaml
VERSION := $(shell grep '^version:' pubspec.yaml | sed 's/version: //' | cut -d'+' -f1)
BUILD := $(shell grep '^version:' pubspec.yaml | sed 's/version: //' | cut -d'+' -f2)

# Default target
all: analyze test build

# Run flutter analyze
analyze:
	@echo "Running flutter analyze..."
	@flutter analyze

# Run tests
test:
	@echo "Running tests..."
	@flutter test

# Build release APK
build:
	@echo "Building release APK..."
	@flutter build apk --release
	@echo "Built: build/app/outputs/flutter-apk/app-release.apk"

# Bump patch version (0.18.5 -> 0.18.6)
bump-patch:
	@echo "Current version: $(VERSION)+$(BUILD)"
	@NEW_PATCH=$$(echo $(VERSION) | awk -F. '{print $$1"."$$2"."$$3+1}'); \
	NEW_BUILD=$$(($(BUILD) + 1)); \
	sed -i "s/^version: .*/version: $$NEW_PATCH+$$NEW_BUILD/" pubspec.yaml; \
	echo "New version: $$NEW_PATCH+$$NEW_BUILD"

# Bump minor version (0.18.5 -> 0.19.0)
bump-minor:
	@echo "Current version: $(VERSION)+$(BUILD)"
	@NEW_MINOR=$$(echo $(VERSION) | awk -F. '{print $$1"."$$2+1".0"}'); \
	NEW_BUILD=$$(($(BUILD) + 1)); \
	sed -i "s/^version: .*/version: $$NEW_MINOR+$$NEW_BUILD/" pubspec.yaml; \
	echo "New version: $$NEW_MINOR+$$NEW_BUILD"

# Full release: analyze, test, build, commit, tag, push, create GitHub release
release: analyze build
	@echo "Creating release v$(VERSION)..."
	@git add -A
	@git commit -m "v$(VERSION): release" --allow-empty
	@git tag v$(VERSION)
	@git push origin main v$(VERSION)
	@gh release create v$(VERSION) build/app/outputs/flutter-apk/app-release.apk \
		--title "v$(VERSION)" \
		--notes "Release v$(VERSION)"
	@echo "Released: https://github.com/zeeshanhaque21/smarterswitch/releases/tag/v$(VERSION)"

# Quick release: bump patch, then release
quick-release: bump-patch release

# Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	@flutter clean
	@rm -rf build/

# Show current version
version:
	@echo "$(VERSION)+$(BUILD)"

# Install dependencies
deps:
	@flutter pub get

# Format code
format:
	@dart format lib/ test/

# Help
help:
	@echo "Available targets:"
	@echo "  analyze       - Run flutter analyze"
	@echo "  test          - Run tests"
	@echo "  build         - Build release APK"
	@echo "  bump-patch    - Bump patch version (0.18.5 -> 0.18.6)"
	@echo "  bump-minor    - Bump minor version (0.18.5 -> 0.19.0)"
	@echo "  release       - Full release (analyze, build, commit, tag, push, gh release)"
	@echo "  quick-release - Bump patch + release"
	@echo "  clean         - Clean build artifacts"
	@echo "  version       - Show current version"
	@echo "  deps          - Install dependencies"
	@echo "  format        - Format code"
