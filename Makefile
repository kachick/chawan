debug:
	nim compile -d:ssl -o:twt src/main.nim
release:
	nim compile -d:release -d:ssl -o:twt src/main.nim
release_opt:
	nim compile -d:danger -d:ssl -o:twt src/main.nim
clean:
	rm ./twt
all: debug release release_opt
