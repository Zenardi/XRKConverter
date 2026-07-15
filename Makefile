VENV := .venv
PY    := $(abspath $(VENV)/bin/python3)
SAMPLE := $(abspath samples/aim_official_test.xrk)

.PHONY: setup test test-py test-swift coverage e2e lint bundle app run clean ci

## setup: create venv, install deps, fetch test fixtures
setup:
	python3 -m venv $(VENV)
	$(PY) -m pip install --upgrade pip
	$(PY) -m pip install -r core/requirements.txt coverage ruff
	bash scripts/fetch_samples.sh

## test: run both test suites
test: test-py test-swift

test-py:
	cd core && $(PY) -m unittest discover -s tests -p 'test_*.py'

test-swift:
	XRK_TEST_PYTHON=$(PY) XRK_TEST_SCRIPT=$(abspath core/xrk2csv.py) XRK_TEST_SAMPLE=$(SAMPLE) \
		bash scripts/swift_test.sh

## coverage: run the 95% coverage gate (Python + Swift Core)
coverage:
	bash scripts/coverage.sh

## e2e: convert every sample through the shipping pipeline and validate
e2e:
	bash scripts/e2e.sh

## lint: ruff (Python) + swiftlint (if installed)
lint:
	$(PY) -m ruff check core scripts
	@command -v swiftlint >/dev/null 2>&1 && swiftlint lint --quiet app || echo "swiftlint not installed; skipping Swift lint"

## bundle: download + embed the relocatable Python runtime with libxrk
bundle:
	bash scripts/bundle_python.sh

## app: build the distributable XRKConverter.app
app:
	bash scripts/build_app.sh

## run: build (if needed) and launch the app
run: app
	open dist/XRKConverter.app

## ci: what the CI pipeline runs
ci: lint coverage e2e

clean:
	rm -rf app/.build dist .cache app/Resources/python
