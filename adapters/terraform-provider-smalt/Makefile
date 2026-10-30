BINARY := terraform-provider-azurerm

.PHONY: check build install clean

check:
	go vet ./...
	go fmt ./...
	go test ./...

build:
	go build -o $(BINARY) .

install: build
	bash scripts/dev_overrides.sh

clean:
	rm -f $(BINARY)
