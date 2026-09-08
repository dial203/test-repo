.PHONY: help install test run openapi

help:
	@echo "make install  - install the service and its dev dependencies"
	@echo "make test     - run the test suite"
	@echo "make run      - run locally on :8000 (HTTPS check disabled)"
	@echo "make openapi  - dump openapi.json"

install:
	pip install -e '.[dev]'

test:
	python3 -m pytest -q

run:
	NOCTURNE_REQUIRE_HTTPS=0 python3 -m uvicorn nocturne_sync.app:app --reload --port 8000

openapi:
	@NOCTURNE_REQUIRE_HTTPS=0 python3 -c "import json; from nocturne_sync.app import app; print(json.dumps(app.openapi(), indent=2))"
