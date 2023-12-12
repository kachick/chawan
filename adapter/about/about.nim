import std/envvars

const chawan = staticRead"res/chawan.html"
const license = staticRead"res/license.html"

proc main() =
  stdout.write("Content-Type: text/html\n\n")
  case getEnv("MAPPED_URI_PATH")
  of "blank": stdout.write("")
  of "chawan": stdout.write(chawan)
  of "license": stdout.write(license)
  else: stdout.write("Error: about page not found")

main()
