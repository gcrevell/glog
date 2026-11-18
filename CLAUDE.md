# CLAUDE.md

`glog` is one bash script, symlinked onto `PATH`, that calls Graylog's REST API with `curl` and shapes the output with `jq`. The README covers install, config and how to check a change.

## Easy to get wrong

- **It has to run on bash 3.2,** the `/bin/bash` macOS ships, as well as bash 5. No associative arrays, `mapfile`, `${var,,}` or empty arrays under `set -u`. Repeated options build newline-separated strings that `jq` splits.
- **Search uses the POST forms** of `/search/messages` and `/search/aggregate`. The GET forms look equivalent, but in Graylog 7.2 `GET /search/messages` silently ignores an absolute `timerange`, and `GET /search/aggregate` rejects `group_by`.
- **The token reaches curl on stdin** (`-K -`), never as an argument, so it can't show up in `ps` or in an error message. Keep it that way.
- **The output is sized for an agent's context.** CSV, ANSI colour codes stripped, newlines in values escaped, values cut to `--width`, floats rounded to two places, and small defaults (25 messages, 1h, top 10 groups). Don't raise the defaults or add columns without a reason.
- **`glog --help` is the only documentation a new session reads,** so a new option or command belongs there too, and it should stay around 45 lines.
- **Keyword ranges** (`-r yesterday`) are sent with the local IANA timezone, so they mean local time. Message timestamps come back in UTC, and `--every` buckets with a UTC offset.
