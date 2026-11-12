# Free Pascal build: `make` produces ./list
FPC   ?= fpc
FLAGS ?= -O2 -XX -CX -Xs -FUbuild

list: list.pas uApp.pas uViewer.pas uScreen.pas uOpts.pas uCP437.pas uSpool.pas
	@mkdir -p build
	$(FPC) $(FLAGS) -Fu. -olist list.pas

clean:
	rm -rf build list

.PHONY: clean
