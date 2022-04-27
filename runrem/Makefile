##### VARIABLES

export PATH += :/cygdrive/c/Apps/Go/bin:/cygdrive/c/Program Files/Sysinternals:/usr/bin

CLIENT  = RunRemClient
SERVER  = RunRemServer
LOCHOST = localhost
REMHOST = cmvmwin7
CMD     = "whoami"
BINS    = $(CLIENT) $(SERVER)
INSTLOC = /cygdrive/c/Users/*/AppData/Local/RunRem/
COPYLOC = /cygdrive/c/Users/client/src/runrem/

##### PHONY TARGETS

all: build

build: $(BINS)

test: build
	./$(SERVER) &
	sleep 2
	./$(CLIENT) $(LOCHOST) $(CMD)
	sleep 2

test-install: install
	./$(CLIENT) $(LOCHOST) $(CMD)
	
client:
	winpty runas /user:client /savecred cmd

clean: kill-server
	-rm -f $(BINS)
	-rm -fr $(INSTLOC)
	-rm -fr $(COPYLOC)

install: test
	./RunRemServer -i

uninstall: kill-server
	./RunRemServer -u

kill-server:
	-pskill -nobanner $(SERVER) 1> /dev/null 2> /dev/null || true

copy: build
	mkdir -p $(COPYLOC)
	cp -r $(BINS) *.go RunRemLib Makefile $(COPYLOC)

help:
	@echo $(MAKE) '{build,test,test-install,install,uninstall,clean,copy,client}'

##### BUILT-IN TARGETS

.PHONY: all build clean test test-install install uninstall copy kill-server client help

##### REAL TARGETS

$(CLIENT): $(CLIENT).go

$(SERVER): $(SERVER).go

##### GENERIC TARGETS

%: %.go
	go build $^
