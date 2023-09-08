import os

import config/config
import display/term
import extern/runproc
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

proc openEditor*(term: Terminal, config: Config, file: string, line = 1): bool =
  var editor = config.external.editor
  if editor == "":
    editor = getEnv("EDITOR")
    if editor == "":
      editor = "vi %s +%d"
  let cmd = formatEditorName(editor, file, line)
  return runProcess(term, cmd)

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
