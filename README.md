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
  release  = "v2026.11.13"
}
```

- **`release`:** a release such as `v2026.11.13`, pinned: Terraform reads its `release.json` from Demiurge's bucket
  (`releases`, where each is locked once published) when it plans, so the plan names each image by digest, and an update
  is a change here that you review. Or, opting in to unattended updates, a channel such as `stable`, which the VM follows
  as Demiurge promotes releases to it: each promotion then runs on the VM, as root, with no review on your side; the VM
  still takes each release's images by the digests its `release.json` records. Either way the VM moves itself onto what
  this names: Convex is exported first, every intellect drained and restarted, everything checked, and the release
  before put back if not. Once the VM has taken a release, it refuses that release under any other digests.
- **Access:** Terraform's identity reads `releases` when it plans a pinned release. The VM pulls Demiurge's images, and
  with a channel reads the channel and its releases' `release.json`, with its own service account, the
  `vm_service_account` output; Demiurge grants both read access, and nothing here holds a credential. A new VM waits on
  its first start until that grant is there.
- **Built here:** with `build_here = true`, the VM reads images from this project's registry (the `registry` output)
  and its channel from a bucket here (the `channels` output) instead of Demiurge's, taking each release's tags to the
  digests they have when it first moves onto it. The organisation's own CI builds each
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
- **Cloud reads:** `readable_projects` gives the `demiurge-reader` account (the `reader_email` output) the read roles
  the Google Cloud connection uses in each project, and BigQuery jobs there. List the BigQuery datasets it may read
  in `readable_datasets`, as `project.dataset`: that is the recommended form, and grants data access on those datasets
  alone. Left empty, it reads every dataset in `readable_projects`. Don't list a production data store holding
  regulated data (PHI, payment or personal data), nor leave the list empty while one sits in a readable project: what
  the reader reads, a granted intellect reads.
- **Network logs:** `network_logs` (default true) turns on Cloud DNS's query log, the only record of the names
  intellects look up, sampled VPC flow logs and Cloud NAT's log. Set it false to save their Cloud Logging cost; the
  VM's own log of every intellect connection except DNS lookups to the VM's resolver (`demiurge_egress`,
  `docs/deploy.md` §3) stays either way.
- **The provider** is passed in, configured for `project`; the module refuses one for another project.
- **DNS:** point `domain` and its `api.` and `site.` names at the `ip_address` output, as A records without a proxy.
