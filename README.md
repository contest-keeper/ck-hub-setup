# ck-infra

Contest Keeper Hub Setup: everything to run Keeper Hub ([`ck-hub`](https://github.com/contest-keeper/ck-hub)) on a server.

| Way | Folder | For |
|---|---|---|
| Docker Compose (Hub + PostgreSQL + automatic HTTPS) | [`compose/`](compose) | One machine you manage: a VM, a spare PC, a VPS |
| Microsoft Azure (Container Apps + PostgreSQL Flexible Server), by Terraform | [`infra/azure/`](infra/azure), guide in [`docs/azure.md`](docs/azure.md) | A managed setup with HTTPS and backups included |

Both run the image `ghcr.io/contest-keeper/ck-hub`, which every Hub release publishes with an SBOM and a
signed build provenance attestation. Pin a version (`:0.1.0`) instead of `latest`.

## Docker Compose

```sh
cd compose
cp .env.example .env          # set POSTGRES_PASSWORD (long, random) and CK_DOMAIN
docker compose up -d
```

Point `CK_DOMAIN` at the machine and open ports 80 and 443: Caddy gets and renews the certificate. Then
make the first organizer account (the password is typed at a prompt, never passed as an argument):

```sh
docker compose run --rm -it hub create-user admin
```

Update with `docker compose pull && docker compose up -d`. The data is in the `db-data` volume; back it
up with `docker compose exec db pg_dump -U ckhub ckhub > backup.sql`.

## Azure

See [`docs/azure.md`](docs/azure.md). In short: run `infra/azure/bootstrap.sh` once, set the GitHub variables and environments it prints,
then let `ck-hub` deploy: every merge to `develop` goes to the develop environment, every release to production.

## Checks

Every pull request checks the Terraform (`fmt`, `validate`), the compose file, the workflows and the
shell scripts.
