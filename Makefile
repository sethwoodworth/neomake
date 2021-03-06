# Do not let mess "cd" with user-defined paths.
CDPATH:=

bash:=$(shell command -v bash 2>/dev/null)
ifeq ($(bash),)
  $(error Could not find bash)
endif
# This is expected in tests.
TEST_VIM_PREFIX:=SHELL=$(bash)
SHELL:=$(bash) -o pipefail

# Use nvim if it is installed, otherwise vim.
ifeq ($(shell command -v nvim 2>/dev/null),)
  DEFAULT_VIM:=vim
else
  DEFAULT_VIM:=nvim
endif

TEST_VIM:=nvim
IS_NEOVIM=$(findstring nvim,$(TEST_VIM))$(findstring neovim,$(TEST_VIM))
# Run testnvim and testvim by default, and only one if TEST_VIM is given.
test: $(if $(TEST_VIM),$(if $(IS_NEOVIM),testnvim,testvim),testnvim testvim)
test_interactive: $(if $(TEST_VIM),$(if $(IS_NEOVIM),testnvim_interactive,testvim_interactive),testnvim_interactive testvim_interactive)

VADER:=Vader!
VADER_OPTIONS:=-q
VADER_ARGS=tests/main.vader tests/isolated.vader
VIM_ARGS='+$(VADER) $(VADER_OPTIONS) $(VADER_ARGS)'

NEOMAKE_TESTS_DEP_PLUGINS_DIR?=build/vim/plugins
TESTS_VADER_DIR:=$(NEOMAKE_TESTS_DEP_PLUGINS_DIR)/vader
$(TESTS_VADER_DIR):
	mkdir -p $(dir $@)
	git clone -q --depth=1 -b display-source-with-exceptions https://github.com/blueyed/vader.vim $@
TESTS_FUGITIVE_DIR:=$(NEOMAKE_TESTS_DEP_PLUGINS_DIR)/vim-fugitive
$(TESTS_FUGITIVE_DIR):
	mkdir -p $(dir $@)
	git clone -q --depth=1 https://github.com/tpope/vim-fugitive $@

DEP_PLUGINS=$(TESTS_VADER_DIR) $(TESTS_FUGITIVE_DIR)

TEST_VIMRC:=tests/vim/vimrc

testwatch: override export VADER_OPTIONS+=-q
testwatch:
	contrib/run-tests-watch

testwatchx: override export VADER_OPTIONS+=-x
testwatchx: testwatch

testx: override VADER_OPTIONS+=-x
testx: test
testnvimx: override VADER_OPTIONS+=-x
testnvimx: testnvim
testvimx: override VADER_OPTIONS+=-x
testvimx: testvim

# Neovim might quit after ~5s with stdin being closed.  Use --headless mode to
# work around this.
# > Vim: Error reading input, exiting...
# > Vim: Finished.
testnvim: TEST_VIM:=nvim
# Neovim needs a valid HOME (https://github.com/neovim/neovim/issues/5277).
testnvim: build/neovim-test-home
testnvim: TEST_VIM_PREFIX+=HOME=$(CURDIR)/build/neovim-test-home
testnvim: TEST_VIM_PREFIX+=VADER_OUTPUT_FILE=/dev/stderr
testnvim: | build $(DEP_PLUGINS)
	$(call func-run-vim)
	
testvim: TEST_VIM:=vim
testvim: TEST_VIM_PREFIX+=HOME=/dev/null
testvim: | build $(DEP_PLUGINS)
	$(call func-run-vim)

# Add coloring to Vader's output:
# 1. failures (includes pending) in red "(X)"
# 2. test case header in bold "(2/2)"
# 3. Neomake's debug log messages in less intense grey
# 4. non-Neomake log lines (e.g. from :Log) in bold/bright yellow.
_SED_HIGHLIGHT_ERRORS:=| contrib/highlight-log --compact vader
# Need to close stdin to fix spurious 'sed: couldn't write X items to stdout: Resource temporarily unavailable'.
# Redirect to stderr again for Docker (where only stderr is used from).
_REDIR_STDOUT:=2>&1 </dev/null >/dev/null $(_SED_HIGHLIGHT_ERRORS) >&2

_COVIMERAGE=$(if $(filter-out 0,$(NEOMAKE_DO_COVERAGE)),covimerage run --append --no-report ,)
define func-run-vim
	$(info Using: $(shell $(TEST_VIM_PREFIX) $(TEST_VIM) --version | head -n2))
	$(_COVIMERAGE)$(if $(TEST_VIM_PREFIX),env $(TEST_VIM_PREFIX) ,)$(TEST_VIM) \
	  $(if $(IS_NEOVIM),$(if $(_REDIR_STDOUT),--headless,),-X) \
	  --noplugin -Nu $(TEST_VIMRC) -i NONE $(VIM_ARGS) $(_REDIR_STDOUT)
endef

# Interactive tests, keep Vader open.
_run_interactive: VADER:=Vader
_run_interactive: _REDIR_STDOUT:=
_run_interactive:
	$(call func-run-vim)

testvim_interactive: TEST_VIM:=vim -X
testvim_interactive: TEST_VIM_PREFIX+=HOME=/dev/null
testvim_interactive: _run_interactive

testnvim_interactive: TEST_VIM:=nvim
testnvim_interactive: TEST_VIM_PREFIX+=HOME=$(CURDIR)/build/neovim-test-home
testnvim_interactive: _run_interactive


# Manually invoke Vim, using the test setup.  This helps with building tests.
runvim: VIM_ARGS:=
runvim: testvim_interactive

runnvim: VIM_ARGS:=
runnvim: testnvim_interactive

# Add targets for .vader files, absolute and relative.
# This can be used with `b:dispatch = ':Make %'` in Vim.
TESTS:=$(wildcard tests/*.vader tests/*/*.vader)
uniq = $(if $1,$(firstword $1) $(call uniq,$(filter-out $(firstword $1),$1)))
_TESTS_REL_AND_ABS:=$(call uniq,$(abspath $(TESTS)) $(TESTS))
FILE_TEST_TARGET=test$(DEFAULT_VIM)
$(_TESTS_REL_AND_ABS):
	$(MAKE) --no-print-directory $(FILE_TEST_TARGET) VADER_ARGS='$@'
.PHONY: $(_TESTS_REL_AND_ABS)

testcoverage: COVERAGE_VADER_ARGS:=tests/main.vader $(wildcard tests/isolated/*.vader)
testcoverage:
	$(RM) .coverage.covimerage
	@ret=0; \
	for testfile in $(COVERAGE_VADER_ARGS); do \
	  $(MAKE) --no-print-directory test VADER_ARGS=$$testfile NEOMAKE_DO_COVERAGE=1 || (( ++ret )); \
	done; \
	exit $$ret

tags:
	ctags -R --langmap=vim:+.vader
.PHONY: tags

# Linters, called from .travis.yml.
LINT_ARGS:=./plugin ./autoload

# Vint.
VINT_BIN=$(shell command -v vint 2>/dev/null || echo build/vint/bin/vint)
build/vint: | build
	$(shell command -v virtualenv 2>/dev/null || echo python3 -m venv) $@
build/vint/bin/vint: | build/vint
	build/vint/bin/pip install --quiet vim-vint
vint: | $(VINT_BIN)
	$| --color $(LINT_ARGS)
vint-errors: | $(VINT_BIN)
	$| --color --error $(LINT_ARGS)

# vimlint
VIMLINT_BIN=$(shell command -v vimlint 2>/dev/null || echo build/vimlint/bin/vimlint.sh -l build/vimlint -p build/vimlparser)
build/vimlint/bin/vimlint.sh: build/vimlint build/vimlparser
build/vimlint: | build
	git clone -q --depth=1 https://github.com/syngan/vim-vimlint $@
build/vimlparser: | build
	git clone -q --depth=1 https://github.com/ynkdir/vim-vimlparser $@
VIMLINT_OPTIONS=-u -e EVL102.l:_=1
vimlint: | $(firstword $(VIMLINT_BIN))
	$(VIMLINT_BIN) $(VIMLINT_OPTIONS) $(LINT_ARGS)
vimlint-errors: | $(firstword VIMLINT_BIN)
	$(VIMLINT_BIN) $(VIMLINT_OPTIONS) -E $(LINT_ARGS)

build build/neovim-test-home:
	mkdir $@
build/neovim-test-home: | build
build/vimhelplint: | build
	cd build \
	&& wget -O- https://github.com/machakann/vim-vimhelplint/archive/master.tar.gz \
	  | tar xz \
	&& mv vim-vimhelplint-master vimhelplint
vimhelplint: export VIMHELPLINT_VIM:=vim
vimhelplint: | $(if $(VIMHELPLINT_DIR),,build/vimhelplint)
	contrib/vimhelplint doc/neomake.txt

# Run tests in dockerized Vims.
DOCKER_REPO:=neomake/vims-for-tests
DOCKER_TAG:=18
NEOMAKE_DOCKER_IMAGE?=
DOCKER_IMAGE:=$(if $(NEOMAKE_DOCKER_IMAGE),$(NEOMAKE_DOCKER_IMAGE),$(DOCKER_REPO):$(DOCKER_TAG))
DOCKER_STREAMS:=-ti
DOCKER=docker run $(DOCKER_STREAMS) --rm \
    -v $(PWD):/testplugin \
    -e NEOMAKE_TEST_NO_COLORSCHEME \
    $(DOCKER_IMAGE)
docker_image:
	docker build -f Dockerfile.tests -t $(DOCKER_REPO):$(DOCKER_TAG) .
docker_push:
	docker push $(DOCKER_REPO):$(DOCKER_TAG)

DOCKER_VIMS:=vim73 vim74-trusty vim74-xenial vim8069 vim-master neovim-v0.1.7 neovim-v0.2.0 neovim-v0.2.1 neovim-v0.2.2 neovim-master
_DOCKER_VIM_TARGETS:=$(addprefix docker_test-,$(DOCKER_VIMS))

docker_test_all: $(_DOCKER_VIM_TARGETS)

$(_DOCKER_VIM_TARGETS):
	$(MAKE) docker_test DOCKER_VIM=$(patsubst docker_test-%,%,$@)

_docker_test: DOCKER_VIM:=vim-master
_docker_test: DOCKER_MAKE_TARGET=$(DOCKER_MAKE_TEST_TARGET) \
  TEST_VIM='/vim-build/bin/$(DOCKER_VIM)' \
  VADER_OPTIONS="$(VADER_OPTIONS)" VADER_ARGS="$(VADER_ARGS)"
_docker_test: docker_make
docker_test: DOCKER_MAKE_TEST_TARGET:=test
docker_test: DOCKER_STREAMS:=-t
docker_test: _docker_test

docker_test_interactive: DOCKER_MAKE_TEST_TARGET:=test_interactive
docker_test_interactive: DOCKER_STREAMS:=-ti
docker_test_interactive: _docker_test

docker_run: $(DEP_PLUGINS)
docker_run:
	$(DOCKER) $(if $(DOCKER_RUN),$(DOCKER_RUN),bash)

docker_make: DOCKER_RUN=make -C /testplugin $(DOCKER_MAKE_TARGET)
docker_make: docker_run

docker_vimhelplint:
	$(MAKE) docker_make "DOCKER_MAKE_TARGET=vimhelplint \
	  VIMHELPLINT_VIM=/vim-build/bin/vim-master"

_ECHO_DOCKER_VIMS:=ls /vim-build/bin | grep vim | sort
docker_list_vims:
	docker run --rm $(DOCKER_IMAGE) $(_ECHO_DOCKER_VIMS)

check_lint_diff:
	@# NOTE: does not see changed files for builds on master.
	@set -e; \
	echo "Looking for changed files (to origin/master)."; \
	CHANGED_VIM_FILES=($$(git diff-tree --no-commit-id --name-only --diff-filter=AM -r origin/master.. \
	  | grep '\.vim$$' | grep -v '^tests/fixtures')) || true; \
	ret=0; \
	if [ "$${#CHANGED_VIM_FILES[@]}" -eq 0 ]; then \
	  echo 'No .vim files changed.'; \
	else \
	  MAKE_ARGS="LINT_ARGS=$${CHANGED_VIM_FILES[*]}"; \
	  echo "== Running \"make vimlint $$MAKE_ARGS\" =="; \
	  $(MAKE) --no-print-directory vimlint "$$MAKE_ARGS" || (( ret+=1 )); \
	  echo "== Running \"make vint $$MAKE_ARGS\" =="; \
	  $(MAKE) --no-print-directory vint "$$MAKE_ARGS"    || (( ret+=2 )); \
	fi; \
	if ! git diff-tree --quiet --exit-code --diff-filter=AM -r origin/master.. -- doc/neomake.txt; then \
	  echo "== Running \"make vimhelplint\" for changed doc/neomake.txt =="; \
	  $(MAKE) --no-print-directory vimhelplint       || (( ret+=4 )); \
	fi; \
	exit $$ret

check_lint: vimlint vint vimhelplint

# Checks to be run with Docker.
# This is kept separate from "check" to not require Docker there.
check_docker:
	@:; set -e; ret=0; \
	echo '== Checking for DOCKER_VIMS to be in sync'; \
	vims=$$($(_ECHO_DOCKER_VIMS)); \
	docker_vims="$$(printf '%s\n' $(DOCKER_VIMS) | sort)"; \
	if ! [ "$$vims" = "$$docker_vims" ]; then \
	  echo "DOCKER_VIMS is out of sync with Vims in image."; \
	  echo "DOCKER_VIMS: $$docker_vims"; \
	  echo "in image:    $$vims"; \
	  (( ret+=8 )); \
	fi; \
	exit $$ret

check:
	@:; set -e; ret=0; \
	echo '== Checking that all tests are included'; \
	for f in $(filter-out main.vader isolated.vader,$(notdir $(shell git ls-files tests/*.vader))); do \
	  if ! grep -q "^Include.*: $$f" tests/main.vader; then \
	    echo "Test not included in main.vader: $$f" >&2; ret=1; \
	  fi; \
	done; \
	for f in $(filter-out main.vader,$(notdir $(shell git ls-files tests/isolated/*.vader))); do \
	  if ! grep -q "^Include.*: isolated/$$f" tests/isolated.vader; then \
	    echo "Test not included in isolated.vader: $$f" >&2; ret=1; \
	  fi; \
	done; \
	echo '== Checking for absent Before sections in tests'; \
	if grep '^Before:' tests/*.vader; then \
	  echo "Before: should not be used in tests itself, because it overrides the global one."; \
	  (( ret+=2 )); \
	fi; \
	echo '== Checking for absent :Log calls'; \
	if grep --line-number --color '^\s*Log\b' $(shell git ls-files tests/*.vader $(LINT_ARGS)); then \
	  echo "Found Log commands."; \
	  (( ret+=4 )); \
	fi; \
	echo '== Checking tests'; \
	output="$$(grep --line-number --color AssertThrows -A1 tests/*.vader \
		| grep -E '^[^[:space:]]+- ' \
		| grep -v g:vader_exception | sed -e s/-/:/ -e s/-// || true)"; \
	if [[ -n "$$output" ]]; then \
		echo 'AssertThrows used without checking g:vader_exception:' >&2; \
		echo "$$output" >&2; \
	  (( ret+=16 )); \
	fi; \
	echo '== Running custom checks'; \
	contrib/vim-checks $(LINT_ARGS) || (( ret+= 16 )); \
	exit $$ret

build/coverage: $(shell find . -name '*.vim')
	$(MAKE) testcoverage
.coverage: build/coverage
	covimerage write_coverage $?/*.profile
coverage: .coverage
	coverage report -m --skip-covered

clean:
	$(RM) -r build
.PHONY: clean

.PHONY: vint vint-errors vimlint vimlint-errors
.PHONY: test testnvim testvim testnvim_interactive testvim_interactive
.PHONY: runvim runnvim tags _run_tests
