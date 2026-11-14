# Keeper Hub on Azure

Two environments, each in its own resource group, with its own state, database and Azure identity:

| Environment | Resource group | Runs | Deployed |
|---|---|---|---|
| `develop` | `rg-ckhub-dev` | the newest `develop` build (`:sha-<commit>`), sleeps when idle | automatically after every merge to `develop` |
| `production` | `rg-ckhub` | a released version (`:0.2.0`), always on | automatically after every Hub release, once you approve it |

What each one contains:

| Resource | Why |
|---|---|
| Container App + environment | Runs the Hub image. Azure gives it an `https://....azurecontainerapps.io` address with its own certificate. One copy at most: the Hub counts login lockouts in memory. |
| PostgreSQL Flexible Server (Burstable B1ms, 32 GB, version 16) | The Hub's data. TLS is required (plain connections are refused), 7 days of backups. |
| Key Vault | Holds the database address, which contains the password. The Container App reads it through its own managed identity. |
| Log Analytics workspace | The Hub's logs (30 days). |

Rough cost: about 15 to 25 EUR a month per database (develop has its own), 5 to 10 EUR for a Container App kept
on, almost nothing for one that sleeps. Check the Azure pricing page for today's numbers.

## How a change reaches Azure

1. A pull request is merged into `develop` in `ck-hub`: the workflow `develop.yml` builds the image, publishes
   `ghcr.io/contest-keeper/ck-hub:sha-<commit>` and `:develop`, and deploys it to the `develop` environment.
2. `develop` is promoted to `main`. `release-please` opens a release pull request that raises the version from the
   commit messages (`feat` raises the minor, `fix` the patch, `feat!` the major) and writes the changelog. Merging it
   tags the release, publishes `:<version>` and `:latest`, and starts the production deploy, which waits for your
   approval in the `production` environment.

The version is never typed by hand. Rolling back is running **Deploy to Azure** with an older version.

## One-time setup

You need the Azure CLI, the GitHub CLI, a subscription where you may create resources and role assignments, and
admin rights on the GitHub organization.

1. **Sign in and run the bootstrap** (it asks before it does anything):

   ```sh
   az login
   bash infra/azure/bootstrap.sh              # optional: location, GitHub owner
   ```

   It makes the resource groups, a locked-down storage account for the Terraform state, and one Entra application
   per environment that GitHub Actions signs in as through OIDC. There is **no client secret** to store or
   rotate: each application only trusts tokens GitHub issues for that environment of `ck-hub` or `ck-infra`,
   and only has rights on its own resource group (plus the state container). A develop deploy cannot touch
   production.

2. **Set the GitHub variables** the script prints (`gh variable set ...`, organization level). They are
   identifiers, not secrets.

3. **Make the environments** `develop` and `production` in both `ck-hub` and `ck-infra` (Settings,
   Environments). On `production`, add yourself as a required reviewer and allow deployments from `main` only. On
   `develop`, allow the `develop` branch only. These rules are what decide who can deploy: Azure trusts the
   environment name.

4. **Make the Hub image public.** On GitHub: the organization's Packages, `ck-hub`, Package settings, change
   visibility to public, so Azure can pull it without a stored token. (It is open source; nothing secret is in the
   image.)

5. **First deploy.** Merge something into `develop` in `ck-hub`, or run **Deploy to Azure** by hand in
   `ck-infra` (environment, image tag, *apply*; run once without *apply* to read the plan). The job summary
   shows the Hub's address.

## First organizer account

The Hub has no default account. Make one with a command that asks for the password at a prompt (it is never
an argument). The container already has the database address and can reach the database, so run it there:

```sh
az containerapp exec -g <rg-ckhub or rg-ckhub-dev> -n <container app name, shown in the deploy summary>   --command "/ck-hub create-user admin"
```

Not verified yet: the image has no shell (it is a minimal image), and `exec` has to start the program
directly with a terminal for the password prompt. If it does not work, use the fallback below.

**Fallback, from your own PC.** This needs the database open to your address and read access to the secret,
and both come from Terraform, so run `terraform apply` locally (see "Deploying from your own PC") with
`allowed_client_ips = ["<your public IP>"]` in `terraform.tfvars`. Give yourself the Key Vault role, then:

```sh
az role assignment create --assignee "$(az ad signed-in-user show --query id -o tsv)"   --role "Key Vault Secrets User" --scope "$(az keyvault show -n <key_vault> --query id -o tsv)"
URL=$(az keyvault secret show --vault-name <key_vault> --name database-url --query value -o tsv)
docker run --rm -it -e CK_DATABASE_URL="$URL" ghcr.io/contest-keeper/ck-hub:0.1.0 create-user admin
```

Remove `allowed_client_ips` afterwards and apply again, so the database is closed to everything but Azure.

Then tell the Hub about your sticks from Keeper Forge (`ck-forge registry push --hub <address> --user admin`).

## A name of your own for the Hub

By default the Hub answers on Azure's address (`https://ca-....azurecontainerapps.io`). `custom_domain` in
the environment's tfvars gives it a name of your own as well, with a free certificate that Azure makes and
renews. Develop uses `hub.dev.contestkeeper.com`.

Make the two DNS records first. Terraform fails, and so does the deploy, if Azure cannot find them. In
Cloudflare set both to **DNS only** (grey cloud): a proxied record hides the check from Azure.

| Type | Name | Value |
|---|---|---|
| CNAME | the hostname, for example `hub.dev` | the output `custom_domain_target` |
| TXT | `asuid.` and the hostname, for example `asuid.hub.dev` | the output `custom_domain_verification_id` |

Both values stay the same as long as the Container App environment is not recreated. Read them with
`terraform output`, or from the last deploy's "Show the address" step. The Hub keeps answering on Azure's
address too, and the deploy's health check still uses that one.

## Deploying from your own PC instead

```sh
cd infra/azure
cp backend.hcl.example backend.hcl && cp terraform.tfvars.example terraform.tfvars   # fill in; backend key = ck-hub-<environment>.tfstate
az login
terraform init -backend-config=backend.hcl
terraform plan -var-file=environments/develop.tfvars     # or production.tfvars
```

## Design choices worth knowing

- **No password anywhere.** The database password is generated while Terraform runs (an ephemeral resource)
  and handed to the database and the Key Vault through write-only arguments. It is not in the state, the
  plan, a variable or a file. `db_password_version` makes a new one. The deploying identity can read it
  from the Key Vault only through role assignments you control.
- **The database is reachable from the Azure network, not private.** The rule `0.0.0.0` means "Azure
  services": a Container App without a virtual network has no fixed address. It still needs the password and
  TLS. A private setup (virtual network, private DNS) is possible later; it costs more and needs more care.
- **One Hub copy.** Login lockouts live in memory, so more than one copy would let an attacker try the
  passwords on each. Do not raise `max_replicas` before that state moves into the database.
- **Updating the Hub** is running the workflow with a new version. Rolling back is running it with the old one.
- **Destroying.** `terraform destroy` removes everything, including the data. The Key Vault has purge
  protection, so its name stays reserved for 30 days.
