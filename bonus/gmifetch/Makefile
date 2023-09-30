CFLAGS = -Wall -Wextra -std=c89 -pedantic -lcrypto -lssl -g -O2

gmifetch: gmifetch.c
	$(CC) $(CFLAGS) gmifetch.c -o gmifetch

.PHONY: clean
clean:
	rm -f gmifetch

.PHONY: all
all: gmifetch
