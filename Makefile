.PHONY: lint test check

lint:
	shellcheck forge-wp-update.sh install.sh

test:
	bats test/forge-wp-update.bats

check: lint test
