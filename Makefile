.PHONY: lint test check syntax-check templates-ci

ANSIBLE_INVENTORY := ansible/inventory/example.yml
PLAYBOOKS := $(wildcard ansible/playbooks/*.yml)
TEMPLATES_DIR := e2b/templates
TEMPLATES_STAMP := $(TEMPLATES_DIR)/node_modules/.ci-stamp

$(TEMPLATES_STAMP): $(TEMPLATES_DIR)/package.json $(TEMPLATES_DIR)/package-lock.json
	npm --prefix $(TEMPLATES_DIR) ci
	@touch $(TEMPLATES_STAMP)

templates-ci: $(TEMPLATES_STAMP)

lint: syntax-check templates-ci
	yamllint .
	ansible-lint
	shellcheck bootstrap.sh tests/bats/helpers/ansible-playbook tests/fixtures/render-template.sh \
	tests/fixtures/build-fc-artifacts-fixture.sh tests/fixtures/build-e2b-dist-fixture.sh \
	tests/fixtures/stub-docker-compose-clickhouse-ttl.sh \
	e2b/build/build.sh ci/*.sh \
	ansible/roles/preflight/files/run-preflight.sh \
	ansible/roles/e2b_host/files/*.sh \
	ansible/roles/e2b_datastores/files/*.sh \
	ansible/roles/e2b_services/files/*.sh \
	ansible/roles/e2b_templates/files/*.sh \
	ansible/roles/traefik/files/*.sh \
	ansible/roles/kodus/files/*.sh \
	ansible/roles/doctor/files/qops-doctor \
	ansible/roles/doctor/files/*.sh
	npm --prefix $(TEMPLATES_DIR) run typecheck

syntax-check:
	@set -e; \
	for pb in $(PLAYBOOKS); do \
		echo "syntax-check: $$pb"; \
		ansible-playbook --syntax-check -i $(ANSIBLE_INVENTORY) "$$pb"; \
	done

test: templates-ci
	bats tests/bats/
	npm --prefix $(TEMPLATES_DIR) test

check: lint test
