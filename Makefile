# Family-standard entry point (campaign decision 4): every family repo exposes
# `make test` / `make lint` so family-dev-handbook templates/ci test-lint
# workflow runs unmodified with its defaults. See issue #6.

.PHONY: test lint

# Bare `make` runs the test suite (same as `make test`) rather than doing
# nothing surprising.
.DEFAULT_GOAL := test

test:
	bash tests/run.sh

# No linter configured yet; kept as a no-op so the family-standard
# `make lint` entry point exists (issue #6 / campaign B2).
lint:
	@echo "lint: no linter configured (no-op)"
