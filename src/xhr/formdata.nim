import html/dom
import js/domexception
import js/javascript
import js/tojs
import types/blob
import types/formdata
import utils/twtstr

import chame/tags

proc constructEntryList*(form: HTMLFormElement, submitter: Element = nil,
    encoding: string = ""): Option[seq[FormDataEntry]]

proc newFormData0*(): FormData =
  return FormData()

proc newFormData*(form: HTMLFormElement = nil,
    submitter: HTMLElement = nil): DOMResult[FormData] {.jsctor.} =
  let this = FormData()
  if form != nil:
    if submitter != nil:
      if not submitter.isSubmitButton():
        return err(newDOMException("Submitter must be a submit button",
          "InvalidStateError"))
      if FormAssociatedElement(submitter).form != form:
        return err(newDOMException("Submitter's form owner is not form",
          "InvalidStateError"))
    this.entries = constructEntryList(form, submitter).get(@[])
  return ok(this)

#TODO filename should not be allowed for string entries
# in other words, this should be an overloaded function, not just an or type
proc append*[T: string|Blob](this: FormData, name: string, value: T,
    filename = opt(string)) {.jsfunc.} =
  when T is Blob:
    let filename = if filename.isSome:
      filename.get
    elif value of WebFile:
      WebFile(value).name
    else:
      "blob"
    this.entries.add(FormDataEntry(
      name: name,
      isstr: false,
      value: value,
      filename: filename
    ))
  else: # string
    this.entries.add(FormDataEntry(
      name: name,
      isstr: true,
      svalue: value
    ))

proc delete(this: FormData, name: string) {.jsfunc.} =
  for i in countdown(this.entries.high, 0):
    if this.entries[i].name == name:
      this.entries.delete(i)

proc get(ctx: JSContext, this: FormData, name: string): JSValue {.jsfunc.} =
  for entry in this.entries:
    if entry.name == name:
      if entry.isstr:
        return toJS(ctx, entry.svalue)
      else:
        return toJS(ctx, entry.value)
  return JS_NULL

proc getAll(ctx: JSContext, this: FormData, name: string): seq[JSValue]
    {.jsfunc.} =
  for entry in this.entries:
    if entry.name == name:
      if entry.isstr:
        result.add(toJS(ctx, entry.svalue))
      else:
        result.add(toJS(ctx, entry.value))

proc add(list: var seq[FormDataEntry], entry: tuple[name, value: string]) =
  list.add(FormDataEntry(
    name: entry.name,
    isstr: true,
    svalue: entry.value
  ))

func toNameValuePairs*(list: seq[FormDataEntry]):
    seq[tuple[name, value: string]] =
  for entry in list:
    if entry.isstr:
      result.add((entry.name, entry.svalue))
    else:
      result.add((entry.name, entry.name))

# https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#constructing-the-form-data-set
proc constructEntryList*(form: HTMLFormElement, submitter: Element = nil,
    encoding: string = ""): Option[seq[FormDataEntry]] =
  if form.constructingentrylist:
    return
  form.constructingentrylist = true

  var entrylist: seq[FormDataEntry]
  for field in form.controls:
    if field.findAncestor({TAG_DATALIST}) != nil or
        field.attrb("disabled") or
        field.isButton() and Element(field) != submitter:
      continue

    if field.tagType == TAG_INPUT:
      let field = HTMLInputElement(field)
      if field.inputType == INPUT_IMAGE:
        let name = if field.attr("name") != "":
          field.attr("name") & '.'
        else:
          ""
        entrylist.add((name & 'x', $field.xcoord))
        entrylist.add((name & 'y', $field.ycoord))
        continue

    #TODO custom elements

    let name = field.attr("name")

    if name == "":
      continue

    if field.tagType == TAG_SELECT:
      let field = HTMLSelectElement(field)
      for option in field.options:
        if option.selected or option.disabled:
          entrylist.add((name, option.value))
    elif field.tagType == TAG_INPUT and HTMLInputElement(field).inputType in {INPUT_CHECKBOX, INPUT_RADIO}:
      let value = if field.attr("value") != "":
        field.attr("value")
      else:
        "on"
      entrylist.add((name, value))
    elif field.tagType == TAG_INPUT and HTMLInputElement(field).inputType == INPUT_FILE:
      #TODO file
      discard
    elif field.tagType == TAG_INPUT and HTMLInputElement(field).inputType == INPUT_HIDDEN and name.equalsIgnoreCase("_charset_"):
      let charset = if encoding != "":
        encoding
      else:
        "UTF-8"
      entrylist.add((name, charset))
    else:
      case field.tagType
      of TAG_INPUT:
        entrylist.add((name, HTMLInputElement(field).value))
      of TAG_BUTTON:
        entrylist.add((name, HTMLButtonElement(field).value))
      of TAG_TEXTAREA:
        entrylist.add((name, HTMLTextAreaElement(field).value))
      else: assert false, "Tag type " & $field.tagType & " not accounted for in constructEntryList"
    if field.tagType == TAG_TEXTAREA or
        field.tagType == TAG_INPUT and HTMLInputElement(field).inputType in {INPUT_TEXT, INPUT_SEARCH}:
      if field.attr("dirname") != "":
        let dirname = field.attr("dirname")
        let dir = "ltr" #TODO bidi
        entrylist.add((dirname, dir))

  form.constructingentrylist = false
  return some(entrylist)

proc addFormDataModule*(ctx: JSContext) =
  ctx.registerType(FormData)
