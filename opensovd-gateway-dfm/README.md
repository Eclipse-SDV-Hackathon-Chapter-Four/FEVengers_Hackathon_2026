# OpenSOVD Gateway with DFM Faults

> Created with AI assistance (Claude Opus 5.5, Anthropic).

Builds the official OpenSOVD gateway with the DFM fault integration from the coaches' reference implementation (`Doctor-Whodunit`, branch `example-first-steps`, `demo/opensovd-core`, by Rama) and serves Guardian faults on the standard SOVD path:

```
GET/DELETE http://<host>:7690/sovd/v1/apps/battery/faults[/{fault-code}]
```

Replaces the standalone SOVD fault bridge (port 7691). DFM and dummy Guardian are unchanged.

## How the source is obtained

Nothing is copied by hand. The `Containerfile` clones the sources during the build, at pinned commits:

| Source | Commit | Used for |
|---|---|---|
| `Eclipse-SDV-Hackathon-Chapter-Four/Doctor-Whodunit` (`example-first-steps`) | `5756330` | `demo/opensovd-core`: gateway + fault provider + DFM adapter |
| `eclipse-opensovd/opensovd-core` | `1bf4c47` | `opensovd-cli/lib`, `opensovd-cli/build` (missing in the example branch) |
| `eclipse-opensovd/fault-lib` | `12dac502` | `dfm_lib` for the adapter, same as our DFM image |

Two fixes are applied in the build (details in the `Containerfile` header):

1. Restore `opensovd-cli/lib` and `opensovd-cli/build`: the example branch's `.gitignore` ignores every `lib/` and `build/` folder, so they were never committed.
2. Repin the adapter's `dfm_lib` from the PR fork (`bburda42dot/fault-lib @ 2b638d84`) to upstream `12dac502`, so gateway and DFM use the same iceoryx2 query protocol.

Built with the stable Rust toolchain (verified with 1.97).

## Build

```bash
cd opensovd-gateway-dfm
podman build -t localhost/opensovd-gateway-dfm:dev .
```

First build: about 10 minutes.

## Run

Start the DFM first (see `FAULT_CHAIN.md`), then:

```bash
podman rm -f bridge sovd 2>/dev/null
podman run -d --name sovd --net=host --ipc=host --pid=host $SEL \
  -v /dev/shm:/dev/shm -v /tmp/iceoryx2:/tmp/iceoryx2 \
  localhost/opensovd-gateway-dfm:dev --dfm-fault-app battery
podman logs sovd
```

`$SEL` is empty on Ubuntu and `--security-opt label=disable` on AutoSD.

Expected log: `Attached DFM fault provider app_id=battery` and `Listening addr=0.0.0.0:7690`.

| Option | Meaning |
|---|---|
| `--dfm-fault-app battery` | Registers app `battery` on host component `hpc` and attaches the DFM provider. Must equal the catalog `id` |
| `--dfm-fault-component <id>` | Same for a component |
| `--mock` | Adds the demo topology |

## Verify

```bash
B=http://127.0.0.1:7690/sovd/v1
curl -s $B/apps | jq                          # contains "battery"
curl -s $B/apps/battery | jq                  # has a "faults" link
curl -s $B/apps/battery/faults | jq
curl -s -i -X DELETE $B/apps/battery/faults   # 204
```

Status keys are camelCase (`testFailed`, `testFailedSinceLastClear`, …), as in the ISO 17978-3 example.

## Fault table

```bash
URL=http://127.0.0.1:7690/sovd/v1/apps/battery/faults ./fault_host.sh   # Ubuntu
URL=http://127.0.0.1:7690/sovd/v1/apps/battery/faults /root/faults.sh   # AutoSD
```

Use the table scripts version that reads both camelCase and snake_case status keys.
