NIMC = nim compile
FLAGS = -d:ssl -o:twt
FILES = src/main.nim

debug:
	$(NIMC) $(FLAGS) -d:small $(FILES)
release:
	$(NIMC) $(FLAGS) -d:release $(FILES)
danger:
	$(NIMC) $(FLAGS) -d:danger $(FILES)
small:
	$(NIMC) $(FLAGS) -d:release -d:small $(FILES)
lowmem:
	$(NIMC) $(FLAGS) -d:release -d:lowmem $(FILES)
clean:
	rm ./twt
