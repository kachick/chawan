all: build
build:
	nim compile -d:ssl -o:twt main.nim
release:
	nim compile -d:release -d:ssl -o:twt main.nim
