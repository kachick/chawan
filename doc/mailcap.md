# Mailcap

Chawan's buffers can only handle HTML and plain text. To make Chawan recognize
other file formats, the mailcap file format can be used.

Note that Chawan's default mime.types file only recognizes a few file
extensions, which may result in your entries not being executed.
Please consult the [mime.types](mime.types.md) documentation for details.

For an exact description of the mailcap format, see
[RFC 1524](https://www.rfc-editor.org/rfc/rfc1524).

## Search path

The search path for mailcap files can be overridden using the configuration
variable `external.mailcap`.

The default search path for mailcap files is:

```
$HOME/.mailcap:/etc/mailcap:/usr/etc/mailcap:/usr/local/etc/mailcap
```

When no mailcap files are found, Chawan simply uses the xdg-open command
for all entries. Note: this will change once file downloading is implemented.

## Format

Chawan tries to adhere to the format described in RFC 1524, with a few
extensions.

### Templating

%s, %t works as described in the standard. %{...} in general does not work,
only %{charset}. (TODO: fix this.)

Also, the non-standard template %u may be specified to get the original URL
of the resource.

If no quoting is applied, Chawan will quote the templates automatically.

Note that $(subprocesses) are not quoted properly yet. We recommend using
something like:

```
x=%s; echo "$(cat "$x")"
```

### Fields

The `test`, `nametemplate` and `copiousoutput` fields are
recognized. Additionally, the non-standard `x-htmloutput` extension field
is recognized too.

* When the `test` named field is specified, the mailcap entry is only used
  if the test command returns 0.  
  Warning: as of now, %s does not work with test.
* `copiousoutput` makes Chawan redirect the output of the external command
  into a new buffer.
* The `x-htmloutput` extension field behaves the same as `copiousoutput`,
  but makes Chawan interpret the command's output as HTML.
* For a description of nametemplate, see the RFC.

## Note

Entries with a content type of text/html are ignored.

## Examples

```
# Note: these examples require an entry in mime.types that sets e.g. md as
# the markdown content type.

# Handle markdown files using pandoc.
text/markdown; pandoc - -f markdown -t html -o -; x-htmloutput

# Show syntax highlighting for JavaScript source files using bat.
text/javascript; bat -f -l es6 --file-name %u -; copiousoutput

# Play music using mpv, and hand over control of the terminal until mpv exits.
audio/*; mpv -; needsterminal

# Play videos using mpv in the background, redirecting its standard output
# and standard error to /dev/null.
video/*; mpv -

# Open OpenOffice files using LibreOffice Writer.
application/vnd.openxmlformats-officedocument.wordprocessingml.document;lowriter %s
# (Wow that was ugly.)

# Following entry will be ignored, as text/html is supported natively by Chawan.
text/html; cha -T text/html -I %{charset}; copiousoutput
```
