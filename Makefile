# This makefile wrapper makes DEBIAN packaging easier. 

OCAML_VERSION ?= 3.11.2
OCAML_LIBDIR ?= $(DESTDIR)/usr/lib/ocaml/
OCAML_FIND ?= ocamlfind

all: build

clean:
	ocamlbuild -clean

build:
	ocamlbuild main.byte main.native arakoon_client.cma arakoon_client.cmxa manifest.pdf

test:
	./main.native --run-all-tests

install: install_client install_server

install_server:
	mkdir -p $(DESTDIR)/usr/bin/
	cp ./main.native $(DESTDIR)/usr/bin/arakoon

install_client:
	mkdir -p $(OCAML_LIBDIR)
	$(OCAML_FIND) install arakoon_client -destdir $(OCAML_LIBDIR) META \
	  _build/src/arakoon_client.cma \
	  _build/src/arakoon_client.cmxa \
	  _build/src/client/arakoon_exc.mli \
	  _build/src/client/arakoon_exc.cmi \
	  _build/src/client/arakoon_exc.cmx \
	  _build/src/client/arakoon_client.mli \
	  _build/src/client/arakoon_client.cmi \
	  _build/src/client/arakoon_remote_client.mli \
	  _build/src/client/arakoon_remote_client.cmi \
	  _build/src/client/arakoon_remote_client.cmx \
          _build/src/arakoon_client.a 

uninstall_client:
	$(OCAML_FIND) remove arakoon_client -destdir $(OCAML_LIBDIR)


.PHONY: install test build install_client
         
