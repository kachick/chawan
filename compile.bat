IF "%1"=="release" GOTO RELEASE

set target=debug
goto compile

:RELEASE
set target=release

:COMPILE
..\nim-1.6.2_x64\nim-1.6.2\bin\nim.exe c -o:cha -d:%target% src/main.nim
