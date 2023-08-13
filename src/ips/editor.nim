import os
import posix

import config/config
import display/term
import io/tempfile

func formatEditorName(editor, file: string, line: int): string =
  result = newStringOfCap(editor.len + file.len)
  var i = 0
  var filefound = false
  while i < editor.len:
    if editor[i] == '%' and i < editor.high:
      if editor[i + 1] == 's':
        result &= file
        filefound = true
        i += 2
        continue
      elif editor[i + 1] == 'd':
        result &= $line
        i += 2
        continue
      elif editor[i + 1] == '%':
        result &= '%'
        i += 2
        continue
    result &= editor[i]
    inc i
  if not filefound:
    if result[^1] != ' ':
      result &= ' '
    result &= file

proc c_system(cmd: cstring): cint {.
  importc: "system", header: "<stdlib.h>".}

proc openEditor*(term: Terminal, config: Config, file: string, line = 1): bool =
  var editor = config.external.editor
  if editor == "":
    editor = getEnv("EDITOR")
    if editor == "":
      editor = "vi %s +%d"
  let cmd = formatEditorName(editor, file, line)
  term.quit()
  let wstatus = c_system(cstring(cmd))
  if wstatus == -1:
    result = false
  else:
    result = WIFEXITED(wstatus) and WEXITSTATUS(wstatus) == 0
    if not result:
      # Hack.
      #TODO this is a very bad idea, e.g. say the editor is writing into the
      # file, then receives SIGINT, now the file is corrupted but Chawan will
      # happily read it as if nothing happened.
      # We should find a proper solution for this.
      result = WIFSIGNALED(wstatus) and WTERMSIG(wstatus) == SIGINT
  term.restart()

proc openInEditor*(term: Terminal, config: Config, input: var string): bool =
  try:
    let tmpdir = config.external.tmpdir
    let tmpf = getTempFile(tmpdir)
    if input != "":
      writeFile(tmpf, input)
    if openEditor(term, config, tmpf):
      if fileExists(tmpf):
        input = readFile(tmpf)
        removeFile(tmpf)
        return true
      else:
        return false
  except IOError:
    discard
