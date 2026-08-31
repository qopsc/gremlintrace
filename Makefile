.PHONY: lint test check syntax-check

ANSIBLE_INVENTORY := ansible/inventory/example.yml
PLAYBOOKS := $(wildcard ansible/playbooks/*.yml)

lint: syntax-check
	yamllint .
	ansible-lint
	shellcheck bootstrap.sh

syntax-check:
	@for pb in $(PLAYBOOKS); do \
		echo "syntax-check: $$pb"; \
		ansible-playbook --syntax-check -i $(ANSIBLE_INVENTORY) "$$pb"; \
	done

test:
	bats tests/bats/

check: lint test
