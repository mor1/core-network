IMAGE_NAME = core-network
VERSION = latest

DATABOX_REG ?= databoxsystems
DATABOX_ORG ?= me-box
DATABOX_ARCHS ?= amd64 arm64v8

.PHONY: all
all:  build publish

.PHONY: build
build: $(patsubst %,build-%,$(DATABOX_ARCHS))

.PHONY: publish
publish: $(patsubst %,publish-%,$(DATABOX_ARCHS))

BUILD=docker build --build-arg DATABOX_ORG=$(DATABOX_ORG)
.PHONY: build-%
build-%:
	$(BUILD) -t $(DATABOX_REG)/$(IMAGE_NAME)-$*:$(VERSION) \
	  -f Dockerfile .
	$(BUILD) -t $(DATABOX_REG)/$(IMAGE_NAME)-relay-$*:$(VERSION) \
	  -f Dockerfile-relay .

.PHONY: publish-%
publish-%:
	docker push $(DATABOX_REG)/$(IMAGE_NAME)-$*:$(VERSION)
	docker push $(DATABOX_REG)/$(IMAGE_NAME)-relay-$*:$(VERSION)

.PHONY: test
test:
	@echo "NO TESTS IMPLEMENTED!"

.PHONY: clean
clean:
	opam config exec -- dune clean || $(RM) -r _build
