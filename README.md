# glog

Search Graylog from the command line. `glog` wraps Graylog's search API in a few commands and prints compact CSV, so an answer to "what's been failing today?" fits in a terminal, or in Claude's context, without a web UI or an MCP server.

```console
$ glog count 'level:<=3' -g source -r 1d
"source","count()"
"file-server",5779
"edge-server",753
"home-assistant",213
"dev-server",29
"stats-server",23
"dns-server",22

$ glog search source:edge-server -n 2 -f timestamp,level,message
"timestamp","level","message"
"2026-11-18T15:45:46.963Z",6,"Finished net-watchdog.service - Check the network path to the gateway, record and recover the interface if it is gone."
"2026-11-18T15:45:46.963Z",6,"net-watchdog.service: Deactivated successfully."
```

## Install

`glog` is one bash script that needs `curl` and `jq`. The dotfiles install (`./install.sh --env personal`) clones this repo to `~/src/glog` and links the script into `~/.local/bin`. To do it by hand:

```sh
git clone https://github.com/gcrevell/glog ~/src/glog
ln -sfn ~/src/glog/glog ~/.local/bin/glog
```

Because it's a symlink, `git -C ~/src/glog pull` updates the command.

## Configure

Create an access token in Graylog under **System > Users and Teams > your user > Edit Tokens**. It searches with that user's permissions. Then put the URL and token in `~/.config/glog/config.vars`:

```sh
mkdir -p ~/.config/glog && chmod 700 ~/.config/glog
cat > ~/.config/glog/config.vars <<'EOF'
GLOG_URL="https://graylog.example"
GLOG_TOKEN="..."
EOF
chmod 600 ~/.config/glog/config.vars
```

`GLOG_URL` and `GLOG_TOKEN` in the environment take precedence over the file, and `GLOG_CONFIG` points at a different file.

## Use

`glog --help` covers every command, option and time-range form, with examples:

| Command | What it prints |
|---|---|
| `glog search [QUERY]` | Matching messages, newest first: 25 of them, values cut to 300 characters |
| `glog count [QUERY]` | Counts or other metrics (avg, percentile, card, ...) grouped by fields and/or time |
| `glog fields` | Fields seen in the time range, with their types |
| `glog streams` | Stream IDs and titles |
| `glog status` | Version, indexer health, journal, input states, system notifications |
| `glog api METHOD PATH [BODY]` | Any other REST call, as raw JSON |

Every command except `api` only reads. `glog api` sends whatever you give it, so `PUT` and `DELETE` change things.

### With Claude Code

Tell Claude to use `glog` (it'll read `glog --help`). To skip the permission prompt on each call, add `"Bash(glog *)"` to `permissions.allow` in `~/.claude/settings.json`.

## Testing a change

There's no test suite. A change is checked with `shellcheck` and by running the commands against a real Graylog. All of them except `api` only read, so this is safe on the live server:

```sh
shellcheck glog
for sh in bash /bin/bash; do   # Homebrew's bash, and macOS's bash 3.2
  $sh ./glog search -n 3
  $sh ./glog search -r "yesterday 2pm to yesterday 3pm" -n 1
  $sh ./glog count 'level:<=3' -g source -g level:2 -r 1d
  $sh ./glog count --every 1h -r 4h -m count
  $sh ./glog fields -r 15m
  $sh ./glog streams
  $sh ./glog status
  $sh ./glog search 'source:('   # should fail with Graylog's parse error
done
```

## Versioning

Every push to `main` is tagged `vYYYY.M.N` by the shared CalVer workflow in [gcrevell/workflows](https://github.com/gcrevell/workflows).
