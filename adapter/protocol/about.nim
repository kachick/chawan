import std/envvars

const chawan = staticRead"res/chawan.html"
const license = staticRead"res/license.html"

template printPage(s: static string) =
  stdout.write("Content-Type: text/html\n\n")
  stdout.write(s)

proc main() =
  case getEnv("MAPPED_URI_PATH")
  of "blank": printPage("")
  of "chawan": printPage(chawan)
  of "license": printPage(license)
  else: stdout.write("Cha-Control: ConnectionError 4 about page not found")

main()
