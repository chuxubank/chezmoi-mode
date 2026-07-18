EMACS ?= emacs
POLYMODE_PATH ?=
POLY_PATH ?=
GO_TEMPLATE_PATH ?=
LOAD_PATH = -L . -L extensions -L test $(foreach path,$(POLYMODE_PATH) $(POLY_PATH) $(GO_TEMPLATE_PATH),-L $(path))
SOURCES = chezmoi-core.el chezmoi-template.el chezmoi.el
EXTENSIONS = extensions/chezmoi-age.el extensions/chezmoi-dired.el \
	extensions/chezmoi-ediff.el
OPTIONAL_EXTENSIONS = extensions/chezmoi-magit.el

PACKAGE_SETUP = \
	--eval "(require 'package)" \
	--eval "(package-initialize)" \
	--eval "(setq load-path (cons \"$(CURDIR)\" (delete \"$(CURDIR)\" load-path)))" \
	--eval "(setq load-path (cons \"$(CURDIR)/test\" (delete \"$(CURDIR)/test\" load-path)))"

ARCHIVES = \
	--eval "(require 'package)" \
	--eval "(add-to-list 'package-archives '(\"melpa\" . \"https://melpa.org/packages/\") t)" \
	--eval "(package-initialize)"

.PHONY: all install-deps compile compile-extensions compile-all-extensions test clean

all: compile test

install-deps:
	$(EMACS) -Q --batch $(ARCHIVES) \
		--eval "(package-refresh-contents)" \
		--eval "(package-install 'polymode)" \
		--eval "(unless (locate-library \"go-template-ts-mode\") (package-vc-install \"https://github.com/chuxubank/go-template-ts-mode\"))" \
		--eval "(unless (locate-library \"poly-any-go-template\") (package-vc-install \"https://github.com/chuxubank/poly-any-template\"))"

compile:
	$(EMACS) -Q --batch $(LOAD_PATH) $(PACKAGE_SETUP) \
		--eval "(setq byte-compile-error-on-warn t)" \
		-f batch-byte-compile $(SOURCES)

compile-extensions: compile
	$(EMACS) -Q --batch $(LOAD_PATH) -L extensions $(PACKAGE_SETUP) \
		--eval "(setq byte-compile-error-on-warn t)" \
		-f batch-byte-compile $(EXTENSIONS)

compile-all-extensions: compile-extensions
	$(EMACS) -Q --batch $(LOAD_PATH) -L extensions $(PACKAGE_SETUP) \
		--eval "(setq byte-compile-error-on-warn t)" \
		-f batch-byte-compile $(OPTIONAL_EXTENSIONS)

test:
	$(EMACS) -Q --batch $(LOAD_PATH) $(PACKAGE_SETUP) \
		-l chezmoi-test \
		-f ert-run-tests-batch-and-exit

clean:
	find . -name '*.elc' -delete
