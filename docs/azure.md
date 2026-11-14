# Keeper Hub on Azure

What gets made, in one resource group (`rg-ckhub`, West Europe by default):

| Resource | Why |
|---|---|
| Container App + environment | Runs the Hub image. Azure gives it an `https://....azurecontainerapps.io` address with its own certificate. One copy at most: the Hub counts login lockouts in memory. |
| PostgreSQL Flexible Server (Burstable B1ms, 32 GB, version 16) | The Hub's data. TLS is required (plain connections are refused), 7 days of backups. |
| Key Vault | Holds the database address, which contains the password. The Container App reads it through its own managed identity. |
| Log Analytics workspace | The Hub's logs (30 days). |

Rough cost with the defaults: about 15 to 25 EUR a month for the database, 5 to 10 EUR for the Container App
kept on (set `min_replicas = 0` to let it sleep when idle), little else. Check the Azure pricing page for today's numbers.

## One-time setup

You need the Azure CLI, a subscription where you may create resources and role assignments, and the GitHub
repository `contest-keeper/ck-hub-setup`.

1. **Sign in and run the bootstrap** (it asks before it does anything):

   ```sh
   az login
   bash infra/azure/bootstrap.sh              # optional: location, repository, environment name
   ```

   It makes the resource group, a locked-down storage account for the Terraform state, and an Entra
   application GitHub Actions signs in as through OIDC. There is **no client secret** to store or rotate:
   the application only trusts tokens GitHub issues for this repository's `production` environment, and it
   only has rights on `rg-ckhub` (plus the state container).

2. **Set the GitHub environment.** In the repository: Settings, Environments, New environment `production`.
   Add yourself as a required reviewer, so every deploy waits for your approval. Add the five **variables**
   the script printed (they are identifiers, not secrets).

3. **Make the Hub image public.** On GitHub: the organization's Packages, `ck-hub`, Package settings, change
   visibility to public, so Azure can pull it without a stored token. (It is open source; nothing secret is
   in the image.)

4. **Deploy.** Actions, **Deploy to Azure**, Run workflow: give the Hub version (for example `0.1.0`) and tick
   *apply*. Run it once without *apply* first to read the plan. The summary shows the Hub's address.

## First organizer account

The Hub has no default account. Make one from your PC; the password is typed at a prompt. Allow your PC's
address to reach the database for the moment (add `allowed_client_ips = ["<your public IP>"]` to a
`terraform.tfvars` in `infra/azure` and run the workflow or `terraform apply`), then:

```sh
URL=$(az keyvault secret show --vault-name <key_vault output> --name database-url --query value -o tsv)
docker run --rm -it -e CK_DATABASE_URL="$URL" ghcr.io/contest-keeper/ck-hub:0.1.0 create-user admin
```

Remove `allowed_client_ips` afterwards and apply again so the database is closed to everything but Azure.

Then tell the Hub about your sticks from Keeper Forge (`ck-forge registry push --hub <address> --user admin`).

## Deploying from your own PC instead

```sh
cd infra/azure
cp backend.hcl.example backend.hcl && cp terraform.tfvars.example terraform.tfvars   # fill in
az login
terraform init -backend-config=backend.hcl
terraform plan
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
