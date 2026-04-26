# s&box Pterodactyl egg + Docker image


## Build the image

```bash
docker build -t ghcr.io/local/sbox:latest .
docker push ghcr.io/local/sbox:latest   
```

If you change the image tag, edit `egg-sbox.json` -> `docker_images` to match.

## Import the egg

1. Pterodactyl panel -> Nests -> create/pick a nest -> Import Egg -> upload `egg-sbox.json`.
2. Create a server using the egg. The install step pulls SteamCMD (anonymous) and downloads app **1892930** into `/home/container`.
3. Allocate two ports for the server: the primary (game) port becomes `SERVER_PORT`, plus a separate UDP port for `QUERY_PORT` (default `27016`).

## Startup

```
./sbox-server.exe +game {{SBOX_GAME}} {{SBOX_MAP}} +hostname "{{SERVER_NAME}}" +port {{SERVER_PORT}} +net_query_port {{QUERY_PORT}} {{EXTRA_ARGS}}
```

Map ident is optional — leave `SBOX_MAP` blank to omit it.

## Notes

- `sbox-server.exe` is a managed .NET binary; it runs on Linux through the .NET 8 runtime that the image installs. The `.exe` extension is just how Facepunch ships it — do not rename it.
- `+net_game_server_token` is optional and only useful once s&box is publicly released; generate one at <https://steamcommunity.com/dev/managegameservers> and pass it through `EXTRA_ARGS` to keep a stable Steam ID across restarts.
- Set `SRCDS_BETA=1` to install the `-beta staging` branch instead of stable. The panel will re-run the installer on reinstall.
- Stop signal is `SIGINT` (`^C`) so the server flushes cleanly on Pterodactyl stop.
