Why Pg BACKREST WITHOUT MANUAL WAL AND TAR FILES?

Why do we now introduce pgBackRest? Because doing this manually by hand in production has massive flaws:

Manual tarballs don't support incremental or differential backups.
The local WAL archive will fill up the disk forever until it crashes.
Restoring by hand requires manually uncompressing files, modifying configs, and creating signal files.
pgBackRest automates all of this, streams backups directly to S3, compresses on the fly, enforces retention policies, and lets you do a PITR with a single CLI command!

