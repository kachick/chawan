when NimMajor >= 2:
  import std/envvars
else:
  import std/os

const chawan = staticRead"res/chawan.html"
const license = staticRead"res/license.md"

template printPage(s, t: static string) =
  stdout.write("Content-Type: " & t & "\n\n")
  stdout.write(s)

proc main() =
  case getEnv("MAPPED_URI_PATH")
  of "blank": printPage("", "text/plain")
  of "chawan": printPage(chawan, "text/html")
  of "license": printPage(license, "text/markdown")
  else: stdout.write("Cha-Control: ConnectionError 4 about page not found")

main()
