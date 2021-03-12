debug:
	nim compile -d:ssl -o:twt main.nim
release:
	nim compile -d:release -d:ssl -o:twt main.nim
release_opt:
	nim compile -d:danger -d:ssl -o:twt main.nim
clean:
	rm ./twt ./dtwt ./twt_opt
all: debug release release_opt
