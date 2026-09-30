.PHONY: format format-check lint test check

format:
	dart format .

format-check:
	dart format --output=none --set-exit-if-changed .

lint:
	flutter analyze

test:
	flutter test

check: format-check lint test