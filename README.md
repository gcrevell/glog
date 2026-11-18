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

`test/run.sh` runs `shellcheck`, starts a throwaway Graylog in Docker, sends it a known set of messages and checks each command's output against them. It runs every check with Homebrew's bash and with macOS's bash 3.2:

```sh
test/run.sh                       # about a minute once the images are pulled
test/run.sh --keep                # leave Graylog up on http://127.0.0.1:19000 (admin/admin)
test/run.sh bash test/bash32      # bash 3.2 in a container, where there's no /bin/bash 3.2
```

The test Graylog, MongoDB and OpenSearch are pinned in [`test/compose.yml`](test/compose.yml) to the versions stats-server runs. Renovate bumps them like any other dependency, and the Test workflow runs on its PR, so a Graylog release that breaks `glog` shows up as a failed check before the server is upgraded.

A field Graylog has just seen for the first time doesn't show in `fields` straight away, so that check looks only for the standard fields. Every command except `api` only reads, so it's also safe to try a change against the live server.

## Versioning

Every push to `main` is tagged `vYYYY.M.N` by the shared CalVer workflow in [gcrevell/workflows](https://github.com/gcrevell/workflows).
