# Spike S3: files on exFAT cards (D-123)

Question: can Undo find files on an exFAT or FAT camera card the way it does on APFS (volume UUID plus file number,
D-91, D-93), across a move and an unplug, and can a file be swapped into place atomically there?

Method (2026-11-21, macOS 26 on this Mac): a 64 MB exFAT disk image attached with `hdiutil`, a file written in
`DCIM/100CANON`, moved within the card, the image detached and attached again; `renamex_np(RENAME_SWAP)` tried on two
files.

| Question | Answer |
|---|---|
| Does the card report a volume UUID? | Yes (`4027DB9C-…`, made from the card's serial number by the system), and it is the same after attaching again |
| Is a file's number kept when it moves within the card? | Yes (11 before and after) |
| Is it kept across detaching and attaching? | Yes (11) |
| Does the system call the card removable and external? | Yes: "Removable Media: Removable", "Device Location: External" |
| `RENAME_SWAP` | Not supported (fails); a replace on exFAT must use the journaled hidden-name sequence (Phase 4) |

Decision: the journal's identity checks work on exFAT cards unchanged; volumes are told apart by UUID (two cards both
named "Untitled" have different UUIDs). Replacing a file in place on a card (Phase 4) never relies on `RENAME_SWAP`.
