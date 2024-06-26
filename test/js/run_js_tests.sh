#!/bin/sh
if ! test "$CHA_TEST_BIN"
then	test -f ../../cha && CHA_TEST_BIN=../../cha || CHA_TEST_BIN=cha
fi
failed=0
for h in *.html
do	printf '%s\r' "$h"
	if ! "$CHA_TEST_BIN" -C config.toml "$h" | diff all.expected -
	then	failed=$(($failed+1))
		printf 'FAIL: %s\n' "$h"
	fi
done
printf '\n'
exit "$failed"
