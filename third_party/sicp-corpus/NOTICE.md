# SICP structured source snapshot

`xml.tar.gz` contains the five chapter XML trees from Source Academy's SICP
repository, commit `35b1a2274eec60046772dd0a4ea80021369226fc`:
https://github.com/source-academy/sicp/tree/35b1a2274eec60046772dd0a4ea80021369226fc/xml

The Scheme edition is *Structure and Interpretation of Computer Programs*,
second edition, by Harold Abelson and Gerald Jay Sussman with Julie Sussman,
licensed CC BY-SA 4.0; see `../xy-reading/CC-BY-SA-4.0.txt` and
https://sicp.sourceacademy.org/. The archive preserves the upstream XML bytes;
only tar metadata was normalized. All 122 XML files were checked against the
Git blob identities in the pinned tree. SHA-256 of this archive:
`02ac17ebbfeabefff177775c2b608fe008a62cb0cfcc34d4e526c83f453c9621`.

The XML includes multiple language editions and solutions. The inventory tool
filters JavaScript, web-only and solution branches and marks the unwrapped
JavaScript-only `ex:access_unassigned` as excluded; its locations are candidates,
not yet verified book exercise numbers or executable test cases. The original
MIT Press chapter code and support files are available at
https://mitp-content-server.mit.edu/books/content/sectbyfn/books_pres_0/6515/sicp.zip/code/index.html.

`mit-allcode.tar.gz` is the unchanged `allcode.tar.gz` linked by the original
MIT Press code index above. It contains all 21 chapter, supporting and
separately distributed system files, not a selection. SHA-256:
`9ac51401a7e57c497f5d68998942bde4751f612b094b52d7dda17f4ba23a18fd`.
The collection is associated with the second edition by Harold Abelson,
Gerald Jay Sussman and Julie Sussman. The MIT Press book page identifies the
edition as CC BY-SA: https://mitpress.mit.edu/9780262510875/structure-and-interpretation-of-computer-programs/.
It is input data for compatibility work, not a claim that every exercise or
chapter is currently executable. Several chapter files contain commented-out
example evaluations, and systems require their respective support code.
