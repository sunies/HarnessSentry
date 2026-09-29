# Privacy

HarnessSentry is designed as a local behavior-metadata recorder, not a content recorder.

## Data stored locally

Depending on the available sensor, a record can contain:

- timestamp, Harness/adapter identifier and optional session identifier;
- process identifier and executable path;
- behavior category such as process launch, file read/write, archive creation or network upload;
- target path, archive name or network hostname;
- evidence level, byte count when available, and small classifier metadata;
- incident disposition and user-created allow rules.

The database is stored at:

```text
~/Library/Application Support/HarnessSentry/HarnessSentry.sqlite
```

SQLite may also create `-wal` and `-shm` sidecar files in the same directory.

## Data deliberately not stored

HarnessSentry does not persist source file contents, prompts, model responses, tool output, credentials, raw request/response bodies, or raw shell commands. For a shell command observed through a Hook, it stores only a SHA-256 digest, a coarse command class and a minimized target when one can be safely extracted.

The Hook process necessarily receives the JSON supplied by the monitored Harness. It parses that input in memory and discards fields that are not part of the minimized record. Inputs larger than 2 MB are rejected. The WorkBuddy audit bridge starts at the end of the current daily log, reads only appended records on a 15-second interval, limits each read to 512 KB, and applies the same command redaction before persistence.

## Network behavior

HarnessSentry itself does not upload the local database or evidence exports. Current Community builds do not inspect packet bodies. A hostname inferred from a tool command is evidence about that command, not proof that a network transfer completed.

## Retention and deletion

Defaults are 24 hours for raw events, 2 days for ordinary behavior, 30 days for incidents and a 200 MB database limit. The application exposes retention and size choices, applies cleanup in the background, and allows individual incidents and allow rules to be removed.

An evidence export is a user-directed JSON file outside the managed database. Retention cleanup does not delete exported files; the user is responsible for protecting and deleting them.

## Sensitive metadata

Even without content, paths, project names, hostnames and session identifiers can be sensitive. Home-directory paths are abbreviated to `~`, and URLs are reduced to hostnames, but exports should still be reviewed before sharing.

## Future sensors

The production Endpoint Security and Network Extension components are not active in the current Community build. The opt-in ZCode lab workflow can consume `eslogger` output only for a marked decoy repository and does not retain the raw stream. Any future sensor that expands collection must preserve data minimization, document new fields and provide an explicit enablement path.
