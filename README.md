# The live demo of Kollaudo

The scenario behind the live demo of [Kollaudo](https://github.com/kollaudo/kollaudo). **Its data is
made up**: a shop with three components, `billing`, `checkout` and `search`, deployed to `dev`,
`staging` and `production`. Each cell of the matrix shows one thing a verdict can say:

| | staging | production |
|---|---|---|
| **billing** `b7e21c4` | **pass (override)**: an e2e test failed, and someone let it through, with a reason, for 24 hours | **pass**, gated: the gate got a pass in staging before the deployment |
| **checkout** `9d07e6b` | **fail**: an e2e test failed, and the smoke tests never ran | **pass**, but **ungated**: deployed by hand after the gate said fail |
| **search** | `5c3a9f8` is **unknown**: its smoke tests never ran, so it can't go on | `41d8e07` **passes**: it passed staging first |

In `dev`, everything passes. The rules are in [`policy.yaml`](policy.yaml).

## Open it

1. Open https://demo.kollaudo.dev.
2. Add a project with this read token: `kol_VQ81iRttbMjk4pck5KXQ9gEbzLTMlgJAxWud2NIJ3us`. It can only read this
   made-up project.

The instance also gates the releases of Kollaudo itself, in another project that this token can't
see.

## How it's made

[`seed.sh`](seed.sh) sends everything with the Kollaudo CLI, as a pipeline would: the policy,
deployments, test runs as CTRF reports, the verdicts the gate asks for, and the override.
[`seed.yml`](.github/workflows/seed.yml) runs it:

- **the whole scenario**, on demand, once the project exists: Actions, *Seed*, *Run workflow*,
  `scenario`;
- **the override**, twice a day, since an override lasts at most 24 hours. The schedule is in UTC,
  and GitHub can start scheduled runs hours late. Until the secrets are set, these runs stop with
  a notice.

GitHub turns off scheduled workflows of a public repository after 60 days without activity. When
it does, the override expires and billing fails in staging: run the workflow again to turn it back
on.

### Set it up

On the Kollaudo instance, create the project and its tokens. Each token can only touch this
project:

```bash
kollaudo-server project create demo
kollaudo-server token create demo --scope ingest --name demo-seed
kollaudo-server token create demo --scope policy --name demo-rules
kollaudo-server token create demo --scope override --name on-call
kollaudo-server token create demo --scope read --name kargo
```

`project create` prints a read token too: that's the one to publish above. Then, in the settings of
this repository, add the variable `KOLLAUDO_URL` and the secrets `DEMO_INGEST_TOKEN`,
`DEMO_POLICY_TOKEN`, `DEMO_OVERRIDE_TOKEN` and `DEMO_GATE_TOKEN` (the `kargo` read token).

To try it against another Kollaudo, set the same variables and run `./seed.sh`. It needs Node.js 24.
