export BUILD_WITHOUT_QUIC = 1

## Feature Used in rebar plugin emqx_plugrel
## The Feature have not enabled by default on OTP25
export ERL_FLAGS ?= -enable-feature maybe_expr

REBAR = $(CURDIR)/rebar3
SCRIPTS = $(CURDIR)/scripts

.PHONY: all
all: rel

.PHONY: ensure-rebar3
ensure-rebar3:
	@$(SCRIPTS)/ensure-rebar3.sh

$(REBAR):
	$(MAKE) ensure-rebar3

.PHONY: compile
compile: $(REBAR)
	$(REBAR) compile

.PHONY: ct
ct: $(REBAR)
	$(REBAR) as test ct -v

.PHONY: eunit
eunit: $(REBAR)
	$(REBAR) as test eunit

.PHONY: cover
cover: $(REBAR)
	$(REBAR) cover

.PHONY: clean
clean: distclean

.PHONY: distclean
distclean:
	@rm -rf _build
	@rm -f rebar.lock

.PHONY: rel
rel: $(REBAR)
	$(REBAR) emqx_plugrel tar

.PHONY: fmt
fmt: $(REBAR)
	$(REBAR) fmt --verbose -w

.PHONY: fmt-check
fmt-check: $(REBAR)
	$(REBAR) fmt --verbose --check

dialyzer: $(REBAR)
	$(REBAR) dialyzer

.PHONY: run
run: rel
	./scripts/run.sh emqx/emqx-enterprise:5.9.0

.PHONY: test
test: $(REBAR)
	$(REBAR) ct -v
