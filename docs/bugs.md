Listing bugs to fix here:

## Object store bugs:

[ ] concurrent writes to the same key corrupt the object / fail with 500

[ ] if a chunked upload is interrupted, the object is saved as a complete object even if it is incomplete

[ ] interrupted uploads leave the .tmp file behind

[ ] if key collides with directory, returns a 500

[x] HEAD returns 404 even for existing keys

[x] DELETE leaves empty directories behind

[x] missing request body size limit / auth

[ ] `PUT /buckets/b/key/` (trailing slash) returns 400 bad path, maybe remove trailing slash?

## Control Plane Issues:

[ ] long running operations block heartbeats, eg `podman run` pulls missing image synchronously causing node to appear dead. move heartbeats to new thread

[x] after server restart, all nodes appear alive for up to 10s even if they are dead

[x] inconsistent error status for unknown IDs / other errors

[ ] add request logging to server

## CLI Issues:

[x] `tc ps` columns misaligned, need to calculate width dynamically

## Other issues:

[ ] Need a readme

[ ] Document how to set up a cluster, plus VM approach

[ ] Implement a cli command to shell into an instance
