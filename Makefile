debug:
	nim compile -d:ssl -o:dtwt main.nim
release:
	nim compile -d:release -d:ssl -o:twt main.nim
release_opt:
	nim compile -d:danger -d:ssl -o:twt_opt main.nim
all: debug release release_opt
