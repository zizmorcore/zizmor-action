.PHONY: pinact
pinact:
	GITHUB_TOKEN=$$(gh auth token) pinact run --update --verify --config .github/pinact.yml
