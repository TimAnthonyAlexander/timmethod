export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer

CORE_DIR := core
IOS_PROJECT := ios/TimMethod.xcodeproj
IOS_SCHEME := TimMethod

SWIFT_FORMAT := $(shell DEVELOPER_DIR=$(DEVELOPER_DIR) xcrun --find swift-format 2>/dev/null)

.PHONY: build test app format check

build:
	cd $(CORE_DIR) && swift build

test:
	cd $(CORE_DIR) && swift test

app:
	xcodebuild -project $(IOS_PROJECT) -scheme $(IOS_SCHEME) \
		-destination 'generic/platform=iOS Simulator' \
		CODE_SIGNING_ALLOWED=NO build

format:
ifeq ($(SWIFT_FORMAT),)
	@echo "swift-format not found on this toolchain (DEVELOPER_DIR=$(DEVELOPER_DIR)) — skipping format."
else
	$(SWIFT_FORMAT) format --configuration .swift-format -i -r $(CORE_DIR)/Sources $(CORE_DIR)/Tests
endif

check: build test app
	@echo "check: build + test + app all passed."
