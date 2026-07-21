EMACS ?= emacs
TEST_GO_TEMPLATE_PATH ?=
TEST_DEPS_DIR ?= .test-deps
TEST_PACKAGE_DIR = $(abspath $(TEST_DEPS_DIR)/elpa)
TEST_TREE_SITTER_DIR = $(abspath $(TEST_DEPS_DIR)/tree-sitter)
POLY_ANY_TEMPLATE_URL ?= https://github.com/chuxubank/poly-any-template
POLY_ANY_TEMPLATE_REV ?= v0.1.14
POLY_ANY_TEMPLATE_DIR = $(abspath $(TEST_DEPS_DIR)/poly-any-template)
POLY_ANY_TEMPLATE_PATHS = $(POLY_ANY_TEMPLATE_DIR)/lisp/shared \
	$(POLY_ANY_TEMPLATE_DIR)/lisp/go-template
TEST_DEP_PATHS = $(TEST_GO_TEMPLATE_PATH) $(POLY_ANY_TEMPLATE_PATHS)
LOAD_PATH = -L . -L test
AGE_LOAD_PATH = -L . -L extensions/chezmoi-age
TEST_LOAD_PATH = $(LOAD_PATH) $(foreach path,$(TEST_DEP_PATHS),-L $(path))
SOURCES = chezmoi-core.el chezmoi-template.el chezmoi-mode.el \
	chezmoi-dired.el chezmoi-ediff.el chezmoi-magit.el \
	chezmoi-transient.el
AGE_SOURCE = extensions/chezmoi-age/chezmoi-age.el

DEPENDENCY_SETUP = \
	--eval "(setq user-emacs-directory (file-name-as-directory \"$(abspath $(TEST_DEPS_DIR))\"))" \
	--eval "(setq package-user-dir \"$(TEST_PACKAGE_DIR)\")" \
	--eval "(require 'package)" \
	--eval "(require 'treesit)" \
	--eval "(add-to-list 'treesit-extra-load-path \"$(TEST_TREE_SITTER_DIR)\")"

PACKAGE_SETUP = $(DEPENDENCY_SETUP) \
	--eval "(package-initialize)" \
	--eval "(setq load-prefer-newer t)" \
	--eval "(setq load-path (cons \"$(CURDIR)\" (delete \"$(CURDIR)\" load-path)))" \
	--eval "(setq load-path (cons \"$(CURDIR)/test\" (delete \"$(CURDIR)/test\" load-path)))"

TEST_PACKAGE_SETUP = $(PACKAGE_SETUP) \
	$(foreach path,$(TEST_DEP_PATHS),--eval "(setq load-path (cons \"$(path)\" (delete \"$(path)\" load-path)))")

ARCHIVES = $(DEPENDENCY_SETUP) \
	--eval "(add-to-list 'package-archives '(\"melpa\" . \"https://melpa.org/packages/\") t)" \
	--eval "(package-initialize)"

.PHONY: all install-deps install-poly-test-dep install-test-deps \
	check-test-deps compile compile-age test test-autoload test-core test-mode \
	test-template test-ediff test-transient test-integration clean

all: compile test

install-deps:
	mkdir -p "$(TEST_PACKAGE_DIR)" "$(TEST_TREE_SITTER_DIR)"
	$(EMACS) -Q --batch $(ARCHIVES) \
		--eval "(package-refresh-contents)" \
		--eval "(dolist (dependency '(magit transient)) (unless (package-installed-p dependency) (package-install dependency)))"

install-poly-test-dep:
	mkdir -p "$(TEST_DEPS_DIR)"
	@if test ! -d "$(POLY_ANY_TEMPLATE_DIR)/.git"; then \
		git clone --depth=1 --filter=blob:none --no-checkout \
			"$(POLY_ANY_TEMPLATE_URL)" "$(POLY_ANY_TEMPLATE_DIR)"; \
	fi
	git -C "$(POLY_ANY_TEMPLATE_DIR)" fetch --depth=1 origin \
		"$(POLY_ANY_TEMPLATE_REV)"
	git -C "$(POLY_ANY_TEMPLATE_DIR)" switch --detach FETCH_HEAD

install-test-deps: install-deps install-poly-test-dep
	$(EMACS) -Q --batch $(ARCHIVES) \
		--eval "(unless (locate-library \"go-template-ts-mode\") (package-vc-install \"https://github.com/chuxubank/go-template-ts-mode\"))" \
		--eval "(unless (package-installed-p 'polymode) (package-install 'polymode))"
	$(EMACS) -Q --batch $(ARCHIVES) \
		--eval "(require 'go-template-ts-mode)" \
		--eval "(unless (treesit-ready-p 'gotmpl) (go-template-ts-mode-install-grammar))"

check-test-deps:
	$(EMACS) -Q --batch $(TEST_LOAD_PATH) $(TEST_PACKAGE_SETUP) \
		--eval "(require 'poly-any-template)" \
		--eval "(require 'poly-any-go-template)" \
		--eval "(unless (treesit-ready-p 'gotmpl) (error \"The gotmpl grammar is unavailable\"))"

compile:
	$(EMACS) -Q --batch $(LOAD_PATH) $(PACKAGE_SETUP) \
		--eval "(setq byte-compile-error-on-warn t)" \
		-f batch-byte-compile $(SOURCES)

compile-age:
	$(EMACS) -Q --batch $(AGE_LOAD_PATH) $(PACKAGE_SETUP) \
		--eval "(setq byte-compile-error-on-warn t)" \
		-f batch-byte-compile $(AGE_SOURCE)

test-autoload:
	$(EMACS) -Q --batch $(LOAD_PATH) $(PACKAGE_SETUP) \
		-l chezmoi-autoload-test \
		--eval "(ert-run-tests-batch-and-exit)"

test-core:
	$(EMACS) -Q --batch $(LOAD_PATH) $(PACKAGE_SETUP) \
		-l chezmoi-core-test \
		--eval "(ert-run-tests-batch-and-exit '(not (tag integration)))"

test-mode:
	$(EMACS) -Q --batch $(LOAD_PATH) $(PACKAGE_SETUP) \
		-l chezmoi-mode-test \
		--eval "(ert-run-tests-batch-and-exit '(not (tag integration)))"

test-template:
	$(EMACS) -Q --batch $(LOAD_PATH) $(PACKAGE_SETUP) \
		-l chezmoi-template-test \
		--eval "(ert-run-tests-batch-and-exit '(not (tag integration)))"

test-ediff:
	$(EMACS) -Q --batch $(LOAD_PATH) $(PACKAGE_SETUP) \
		-l chezmoi-ediff-test \
		--eval "(ert-run-tests-batch-and-exit '(not (tag integration)))"

test-transient:
	$(EMACS) -Q --batch $(LOAD_PATH) $(PACKAGE_SETUP) \
		-l chezmoi-transient-test \
		--eval "(ert-run-tests-batch-and-exit '(not (tag integration)))"

test-integration: check-test-deps
	CHEZMOI_TEST_INTEGRATION=1 \
	$(EMACS) -Q --batch $(TEST_LOAD_PATH) $(TEST_PACKAGE_SETUP) \
		-l chezmoi-core-test \
		-l chezmoi-mode-test \
		-l chezmoi-template-test \
		-l chezmoi-host-mode-test \
		-l chezmoi-transient-test \
		--eval "(ert-run-tests-batch-and-exit '(tag integration))"

test: test-autoload test-core test-mode test-template test-ediff \
	test-transient test-integration

clean:
	find . -path './$(TEST_DEPS_DIR)' -prune -o -name '*.elc' -exec rm -f {} +
