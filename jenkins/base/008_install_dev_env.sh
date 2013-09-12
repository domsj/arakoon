#!/bin/bash -xue

which opam > /dev/null || { echo 'opam not found!'; exit 1; }
{ opam remote list | grep Incubaid/opam-repository-devel > /dev/null; } || { opam remote add incubaid-devel -k git git://github.com/Incubaid/opam-repository-devel.git; }

opam switch 4.01.0
eval `opam config env`

opam update -y
opam pin camltc none || true
opam install -y ssl
opam install conf-libev
opam install -y camlbz2
opam install -y "lwt.2.4.3"
opam install -y "camltc.999"
opam install -y bisect
