# Demiurge on Google Cloud

Terraform for an organisation's own Demiurge: one VM running Convex and the intellects, Cloud SQL for Convex's data, one
HTTPS load balancer as the only way in, Secret Manager, and a bucket for Convex's exports. Published here from each
Demiurge release; pin a commit. An organisation that vendors Demiurge through its release sync (`docs/deploy.md` §8)
names its copy instead, e.g. `source = "../../third_party/demiurge/infra/gcp"`.

```hcl
provider "google" {
  alias   = "demiurge"
  project = "acme-demiurge"
  region  = "us-central1"
}

module "demiurge" {
  source    = "git::https://github.com/demiurge-lab/terraform-google-demiurge.git?ref=<commit>"
  providers = { google = google.demiurge }

  project  = "acme-demiurge"
  domain   = "demiurge.acme.example"
  org_name = "Acme"
  release  = "stable"
}
```

- **`release`:** a channel such as `stable`, which the VM follows as Demiurge promotes releases (an update needs no
  change here), or a release such as `v2026.11.13` to pin one. The VM moves itself onto whatever it names: Convex is
  exported first, every intellect drained and restarted, everything checked, and the release before put back if not.
- **Access:** the VM pulls Demiurge's images and reads its channel with its own service account, the
  `vm_service_account` output, which Demiurge grants read access; nothing here holds a credential. A new VM waits on its
  first start until that grant is there.
- **Built here:** with `build_here = true`, the VM reads images from this project's registry (the `registry` output)
  and its channel from a bucket here (the `channels` output) instead of Demiurge's. The organisation's own CI builds each
  release from its vendored copy into them, as one of `builders`, which are granted write on both.
- **Tunnel:** with `tunnel = true`, a Cloudflare Tunnel is the way in instead of the load balancer. Make the tunnel, its
  routes (on the domain, `/api/` paths to `http://127.0.0.1:3210` and the rest to `:8080`; `site.`, or `site_domain`,
  to `:3211`) and DNS yourself, and write its token as a version of the `tunnel_secret` output; `ip_address` is then
  null. Convex is then served from the domain itself, not `api.`, so an Access application on the domain covers the
  page and Convex. Behind Cloudflare's proxy, set `site_domain` to a first-level name: Universal SSL covers only one
  level below the zone.
- **Sign-in:** with `oidc`, people also sign in through the organisation's own provider, so nobody needs Slack to
  reach the page. Behind a tunnel with Access, an Access for SaaS application is that provider: the same Access login
  signs them in. Write its client secret as a version of `demiurge-oidc-client-secret` here.
- **The provider** is passed in, configured for `project`; the module refuses one for another project.
- **DNS:** point `domain` and its `api.` and `site.` names at the `ip_address` output, as A records without a proxy.
