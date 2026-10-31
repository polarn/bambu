DESTDIR ?= $(HOME)/.local/bin

.PHONY: build clean install

build:
	go build -o ./build/bambu-ctl ./cmd/bambu-ctl

install: build
	@mkdir -p $(DESTDIR)
	rm -f $(DESTDIR)/bambu-ctl
	cp ./build/bambu-ctl $(DESTDIR)/

clean:
	rm -rf ./build
