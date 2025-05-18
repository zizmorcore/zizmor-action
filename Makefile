VENV ?= .venv

.PHONY: dev
dev: $(VENV)/pyvenv.cfg

$(VENV)/pyvenv.cfg: dev-requirements.txt
	uv venv $(VENV)
	uv pip install -r $<

.PHONY: lint
lint: $(VENV)/pyvenv.cfg
	uv run ruff format --check && \
	uv run ruff check && \
	uv run mypy .

.PHONY: format
format: $(VENV)/pyvenv.cfg
	uv run ruff format && \
	uv run ruff check --fix
