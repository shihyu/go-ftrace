# Warn: 
# 1. To load ebpf program into kernel require special privileges, 
#    we just use `sudo` to do that.
# 2. You may modify and build ths tool again, so you may want to 
#    avoid copying the binary to /usr/sbin again and again, which
#    is searchable by `sudo`, so we use `ln -sf` to create a symbolic
#    link to ~/go/bin/ftrace instead.
all:
	cd cmd/ftrace && go build -v

GOBIN := $(shell go env GOBIN)
ifeq ($(GOBIN),)
GOBIN := $(shell go env GOPATH)/bin
endif

install:
	cd cmd/ftrace && go install -v
	sudo ln -sf $(GOBIN)/ftrace /usr/sbin/ftrace
	sudo chown root:root $(GOBIN)/ftrace
	sudo chmod u+s $(GOBIN)/ftrace

clean:
	rm -f $(GOBIN)/ftrace
	sudo rm -rf /usr/sbin/ftrace

.PHONY: clean
