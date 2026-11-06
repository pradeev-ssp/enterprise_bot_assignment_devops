# DevOps take-home

A small FastAPI service with a Docker image and Helm chart for kind. `/` returns
the application name, version and hostname; `/healthz` returns HTTP 200. The
container runs as UID `10001` on port `8000`.

## Run it

Use Linux or WSL with Bash, Docker, kind, kubectl and Helm installed. Docker
must be running, with WSL integration enabled if applicable. Keep host ports
`80` and `443` free. From the repository root:

```bash
chmod +x setup.sh
./setup.sh
./setup.sh
```

Setup creates or reuses cluster `demo`, installs ingress-nginx, builds and loads
`demo-app:v1`, then installs release `demo` in namespace `demo`. The second run
checks repeatability. A reused cluster needs the same port mappings as the one
created by the script; setup does not validate that.

The two-run test is still pending. Before submission, save the script's
executable bit in Git with `git update-index --chmod=+x setup.sh`; it is
currently tracked as non-executable.

## Check the service

```bash
kubectl --context kind-demo -n demo rollout status deployment/demo --timeout=180s
kubectl --context kind-demo -n demo get deployments,pods,services,ingresses

curl -fsS --resolve demo.local:80:127.0.0.1 http://demo.local/
curl -fsS --resolve demo.local:80:127.0.0.1 http://demo.local/healthz
```

`--resolve` avoids a hosts-file change. The expected root response contains
`enterprise-bot`, version `1.0.0`, and the serving pod's hostname. Health should
return `{"status":"healthy"}`. Ingress verification on kind is still pending.

## Configuration

Defaults are in `chart/values.yaml`: two replicas, image `demo-app:v1`, and host
`demo.local`. The service reads `APP_NAME` and `VERSION` from ConfigMap files
mounted at `/etc/demo-config` on each request. Without those files, it uses
environment variables, then built-in defaults.

To check a ConfigMap update without restarting pods:

```bash
kubectl --context kind-demo -n demo patch configmap demo-config --type merge \
  -p '{"data":{"APP_NAME":"config-check","VERSION":"2.0.0"}}'

curl -fsS --resolve demo.local:80:127.0.0.1 http://demo.local/
```

Mounted updates [take time to reach the pods](https://kubernetes.io/docs/concepts/configuration/configmap/#mounted-configmaps-are-updated-automatically),
so repeat the request until both replicas show the new values. This runtime
check is still pending. Restore the defaults afterward:

```bash
kubectl --context kind-demo -n demo patch configmap demo-config --type merge \
  -p '{"data":{"APP_NAME":"enterprise-bot","VERSION":"1.0.0"}}'
```

The chart passed strict lint and rendering checks for replica and config
overrides. To repeat:

```bash
helm lint ./chart --strict
helm template demo ./chart --namespace demo \
  --set replicaCount=3 \
  --set config.appName=override-check \
  --set-string config.version=2.0.0
```

## Resource choices

Each replica requests `100m` CPU and `128Mi` memory, with limits of `500m` and
`256Mi`. This reserves a modest budget for the Python service and allows CPU
bursts while bounding resource use. These are estimates; no load test has been
run. Low limits could cause throttling or memory-related restarts, so production
values need measurements under normal and peak traffic. The lab has separate
settings.

## Debug lab

Part 4 is incomplete: the last run had 9 checks passing and 2 failing. Reporter
can list pods but reports `unexpected end of JSON input` and fails readiness.
The run used Docker Desktop Kubernetes; kind validation is still pending.

See [lab/FINDINGS.md](lab/FINDINGS.md) and `lab/part4-session.log` for the evidence.
Append to the recording when continuing, keeping the supplied scenario,
cluster-state files and image unchanged.

## What I left out

- TLS: the demo uses HTTP, so traffic is unencrypted.
- Autoscaling and node-failure testing: two replicas on one node cannot cover
  node loss or sustained overload.
- Load testing and CI image scanning: sizing and dependency security still
  need validation. The optional CI bonus is not implemented.

For production, I would add HTTPS, monitoring, measured resource settings and
multiple nodes. I'd also use a pipeline with tests, image scans and unique image
tags or digests. Setup currently reuses `v1`, so a rebuild alone does not trigger
a rollout. The required ingress-nginx deployment would need replacing; the
migration plan is in [ANSWERS.md](ANSWERS.md).

## How I used AI

I used Codex for repository review, Helm templates, lab fixes and documentation
drafts. I ran the lab commands and supplied the terminal output. One correction
was fetching logs from both reporter pods after the first command selected an
old pod. The RBAC fix also left a separate parsing failure unresolved; that is
recorded in the findings.
