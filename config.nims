switch("import", "utils/eprint")

# workaround for GCC 14
when defined(gcc):
  switch("passC", "-fpermissive")
