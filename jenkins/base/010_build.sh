

echo WORKSPACE=${WORKSPACE}
BUILD_ENV=${WORKSPACE%${JOB_NAME}}
echo BUILD_ENV=${BUILD_ENV}
eval `${BUILD_ENV}/ROOT/OPAM/bin/opam --root ${BUILD_ENV}/ROOT/OPAM_ROOT config -env`

ocamlfind printconf
ocamlfind list
ocamlbuild -clean
ocamlbuild -use-ocamlfind arakoon.native arakoon.byte
#make coverage 
#./arakoon.d.byte --run-all-tests-xml foobar.xml
./arakoon.native --run-all-tests-xml foobar.xml
./report.sh
# redo this for artifacts...
ocamlbuild -use-ocamlfind arakoon.native arakoon.byte
mkdir -p doc/python/client
epydoc --html --output ./doc/python/client --name Arakoon --url http://www.arakoon.org --inheritance listed --graph all src/client/python
mkdir -p doc/python/client/extension
epydoc --html --output ./doc/python/client/extension --name "Arakoon PyLabs client extension" --url http://www.arakoon.org --inheritance listed --graph all extension/client/*.py
mkdir -p doc/python/server/extension
epydoc --html --output ./doc/python/server/extension --name "Arakoon PyLabs server extension" --url http://www.arakoon.org --inheritance listed --graph all extension/server/*.py
cp arakoon.native arakoon
