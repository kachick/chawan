This directory contains adapters for protocols and file formats not directly
supported by the main executable.

A long-term goal is to eventually move out all protocol-related functionality
(except local CGI + urimethodmap) to here. Also, support for file formats
except HTML and plain text should be placed here as well; we already only
support non-HTML file formats through built-in converters.
