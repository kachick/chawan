switch("import", "utils/eprint")

# workaround for clang 16
when defined(clang):
  switch("passC", "-Wno-error=incompatible-function-pointer-types")
