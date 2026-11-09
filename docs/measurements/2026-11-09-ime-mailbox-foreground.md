# Foreground IME mailbox bridge

The foreground bridge opens the dictionary mailbox, attaches the asynchronous
workspace IME only after a successful pin, and copies each page completion
into the matching outstanding request. Missing dictionaries leave the builtin
dictionary active. Shutdown cancels conversion, drains any submitted read,
detaches the workspace and coordinator, then releases the pin. A request that
was never submitted can be drained locally. Unknown or mismatched replies
fence the bridge instead of releasing an uncertain pin.

Host integration exercises the workspace and the production mailbox with the
bundled NFST through a modeled backend, including normal conversion, missing
dictionary, cancellation, unsent requests, read errors and shutdown. This is
not a native-task or physical-SD execution.

An attempted direct hookup to the native foreground failed the existing
49,152-byte SRAM heap-floor link assertion, including after moving the
foreground conversion functions to mapped Flash. That attempted hookup and
its experimental placement changes are not enabled here; the heap-floor
assertion remains intact. The remaining work is to identify and qualify an
acceptable native code/data placement, then wire the UI lifecycle and test
real media. The current store still cannot contain the large dictionary.
