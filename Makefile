all: build
build:
	nim compile -d:ssl -o:twt main.nim
