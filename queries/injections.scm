; Inline Python blocks (::py:: ... ::py::)
((pyinline) @injection.content
 (#set! injection.language "python"))

; Comments
((comment) @injection.content
 (#set! injection.language "comment"))
