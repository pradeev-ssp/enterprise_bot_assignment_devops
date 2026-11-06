# Part 4 findings

The lab is not fully working yet. The last verification finished with 9 checks
passing and 2 failing, both related to reporter.

The session is saved in [part4-session.log](part4-session.log). The output below
is excerpted from that recording, with terminal colours removed. The run used
Docker Desktop Kubernetes through WSL. Validation on kind is still pending;
`kind` was not installed when the session ended.

## Additional startup issue — image user could not be verified

**Symptom:** All six workloads were blocked by `CreateContainerConfigError`
after the migration Job was accepted. Describing the backend pod showed:

```text
  Warning  Failed     3m18s (x95 over 23m)  kubelet            spec.containers{backend}: Error: container has runAsNonRoot and image has non-numeric user (nonroot), cannot verify user is non-root (pod: "backend-5cb957846d-kjb95_debug-lab(3b3b6466-e2ce-45fd-86df-9c05da0e41d5)", container: backend)
```

**Cause:** The image declares its user as `nonroot`. With `runAsNonRoot: true`
and no explicit numeric UID, kubelet could not verify that account.

**Fix:** Added `runAsUser: 65532` to all six container security contexts and
kept `runAsNonRoot: true`. The image repository and tag were left unchanged.

**How I found it:** Started with the pod description, then inspected the image
user and read `/etc/passwd` from a stopped inspection container:

```bash
docker image inspect docker.io/ebinterview/eb-debug-app:1.0.1 --format '{{.Config.User}}'
docker create --name eb-user-check docker.io/ebinterview/eb-debug-app:1.0.1
docker cp eb-user-check:/etc/passwd - | tar -xOf -
docker rm eb-user-check
```

The account entry confirmed the UID:

```text
nonroot:x:65532:65532:nonroot:/home/nonroot:/sbin/nologin
```

After applying the numeric UID, the replacement containers could start and the
application-level failures became visible.

## Defect 1 — migration Job rejected at installation

**Symptom:** The first `./scenario.sh up` failed with:

```text
Error: 1 error occurred:
	* Job.batch "migrate" is invalid: spec.template.spec.restartPolicy: Required value: valid values: "OnFailure", "Never"
```

**Cause:** `templates/migrate-job.yaml` used `restartPolicy: Always`, which is
not valid for a Job.

**Fix:** Changed the policy to `Never`. The existing `backoffLimit: 2` still
lets the Job controller retry failed attempts with new pods.

**How I found it:** Followed the field named in the installation error back to
the Job template. The next install created the Job, but it also hit the shared
UID issue described above. Applying that security-context change to the
existing Job produced a `field is immutable` error. The blocked Job had to be
deleted and recreated through the chart:

```bash
kubectl -n debug-lab delete job migrate --wait=true
./scenario.sh up
kubectl -n debug-lab get jobs,pods
```

It then completed:

```text
job.batch/migrate   Complete   1/1           6s         8s
```

The Job remains enabled in the chart.

## Defect 2 — application port did not match probes and Services

**Symptom:** Backend was running but stayed unready. Its startup log said:

```text
2026/11/06 19:00:47 eb-debug-app 2.0.0 starting: mode=api pod=backend-bf84ddf78-zsnth listening on :8081 (image default is 8081; set PORT to override)
```

The pod events showed the probe going to a different port:

```text
  Warning  Unhealthy  34s (x25 over 2m27s)  kubelet            spec.containers{backend}: Readiness probe failed: Get "http://10.1.0.118:8080/healthz": dial tcp 10.1.0.118:8080: connect: connection refused
```

**Cause:** The chart declared port `8080`, but that did not configure the
application's listener. The image defaults to `8081` without a `PORT`
environment variable.

**Fix:** Added `PORT` to all five Deployment templates, taking its value from
`common.port`. This keeps the application listener, container port, probes,
and Service target ports on the same setting.

**How I found it:** Compared `kubectl logs` with `kubectl describe pod` for the
same backend pod. Gateway and reporter startup logs also showed `8081`. After
the change, backend rolled out successfully. A separate BusyBox probe later
confirmed HTTP access through the Service:

```text
Connecting to backend:8080 (10.108.94.197:8080)
  HTTP/1.1 200 OK
```

## Defect 3 — worker cache was on a read-only filesystem

**Symptom:** Worker entered `CrashLoopBackOff`. Its previous container log
showed:

```text
2026/11/06 19:02:13 FATAL: worker could not initialise its cache: mkdir /var/cache/app: read-only file system — the process needs a writable directory at /var/cache/app (mount a volume there, or set CACHE_DIR)
```

**Cause:** The worker needed to write under `/var/cache/app`, but its root
filesystem was read-only and the chart provided no writable volume there.

**Fix:** Mounted an `emptyDir` at `/var/cache/app` and set the pod's `fsGroup`
to `65532` so the non-root process could write to it. Kept the rest of the
root filesystem read-only. The cache is disposable; the volume does not
preserve it across pod replacement.

**How I found it:** Read the previous crash log:

```bash
kubectl -n debug-lab logs worker-5bc66bc574-8qspr --previous --tail=80
```

The error gave the exact path and suggested a volume or `CACHE_DIR`. A volume
at the existing cache path avoided changing the application's configuration.
After the cache and port changes, the worker rollout succeeded and the
verifier reported it ready with no crash loops.

## Defect 4 — metrics exceeded the namespace CPU ceiling

**Symptom:** The replacement metrics pod was never created. The ReplicaSet
events included:

```text
  Warning  FailedCreate  2m32s                replicaset-controller  Error creating: pods "metrics-7d4f649b5f-wkc7f" is forbidden: maximum cpu usage per Container is 1, but limit is 4
```

**Cause:** Metrics requested 2 CPUs and had a limit of 4. The namespace
LimitRange permits at most 1 CPU per container, so admission rejected the new
pod. There was no new metrics container to inspect with `kubectl logs`.

**Fix:** Changed the chart's metrics CPU request to `50m` and limit to `200m`,
matching the other small API workloads. Memory settings stayed at `64Mi`
requested and `128Mi` limited. These CPU values are starting estimates, not
the result of a load test. The namespace guardrails were not changed.

**How I found it:** Described both metrics ReplicaSets:

```bash
kubectl -n debug-lab describe replicaset -l app=metrics
```

The old ReplicaSet still had a pod from the initial install, while the new
one had zero pods and repeated `FailedCreate` events. After reducing the CPU
settings, metrics rolled out and reached `1/1` ready.

## Defect 5 — gateway pointed at the wrong namespace

**Symptom:** Backend became ready, but gateway remained unready and the
verifier reported:

```text
  FAIL  gateway /status does not report backend=ok
```

**Cause:** The gateway's `BACKEND_URL` in `values.yaml` was
`http://backend.default.svc:8080`. The backend Service was in `debug-lab`, not
`default`.

**Fix:** Changed the URL to `http://backend:8080`. Gateway and backend run in
the same namespace, so the short Service name resolves to the intended
backend.

**How I found it:** Used a temporary BusyBox pod to check backend DNS and
HTTP access. It resolved `backend.debug-lab.svc.cluster.local` and received
HTTP 200 from `backend:8080/healthz`. Compared that working address with the
gateway value in the chart. The initial gateway log command selected an older
pod still listening on `8081`, so that log alone did not describe the latest
rollout. After correcting the URL, the final verification included:

```text
  PASS  deployment gateway: 1/1 ready
  PASS  gateway /status reports backend=ok
```

## Defect 6 — reporter permissions were bound to the wrong account

**Symptom:** The verifier reported that the reporter ServiceAccount could not
list pods. The reporter logs also showed HTTP 403 responses from Kubernetes.
The live RoleBinding had this subject:

```yaml
subjects:
- kind: ServiceAccount
  name: default
  namespace: debug-lab
```

**Cause:** The reporter Deployment used ServiceAccount `reporter`, while the
RoleBinding granted the `reporter-read` Role to `default`. The Role already
contained `get` and `list` permissions for pods.

**Fix:** Made the ServiceAccount resource and RoleBinding subject use
`reporter.serviceAccountName`, which the Deployment already used. Kept the
Role limited to the existing namespace-scoped pod permissions.

**How I found it:** Checked the reporter logs and the live binding:

```bash
kubectl -n debug-lab logs deployment/reporter --tail=50
kubectl -n debug-lab get rolebinding reporter-read -o yaml
```

The first log command picked the old pod. Fetching logs by `app=reporter`
with pod prefixes exposed the newer pod's 403 errors. After the binding
change, verification confirmed the permission fix:

```text
  PASS  ServiceAccount debug-lab/reporter can list pods
```

Reporter itself still did not become ready. That remaining failure is covered
below; fixing the RoleBinding did not finish this workload.

## Still open — reporter cannot parse the pod list

After the permission change, the newer reporter pod stopped logging 403s and
started reporting:

```text
2026/11/06 19:16:02 pod list failed: parse pod list: unexpected end of JSON input
2026/11/06 19:16:02 GET /healthz -> 503 (from 10.1.0.1:53210)
```

The pod description confirmed `PORT=8080`, `NAMESPACE=debug-lab`, and
ServiceAccount `reporter`. Its readiness probe was receiving HTTP 503.

To check the permission and API response separately from the application,
queried Kubernetes while impersonating the reporter account:

```bash
kubectl -n debug-lab get pods --as=system:serviceaccount:debug-lab:reporter -o name
kubectl get --raw /api/v1/namespaces/debug-lab/pods \
  --as=system:serviceaccount:debug-lab:reporter > /tmp/reporter-pods.json
wc -c /tmp/reporter-pods.json
python3 -m json.tool /tmp/reporter-pods.json >/dev/null \
  && echo "API response is valid JSON"
```

The pod listing succeeded. The saved response size and validation output were:

```text
44411 /tmp/reporter-pods.json
API response is valid JSON
```

This shows that a request using the reporter's identity could retrieve valid
JSON through kubectl. It does not establish what body the reporter process
received or why its parsing failed. A response-reading problem in the
application is a possibility, but the response size alone does not prove a
buffer limit or truncation. No workaround was applied for this error.

The next step would be to reproduce the same chart on kind, then compare an
authenticated request from inside a pod with the reporter's failure if it
persists. The session ended after confirming the current environment:

```bash
kubectl config current-context
kind get clusters
```

Output excerpts:

```text
docker-desktop
Command 'kind' not found, did you mean:
```

There is no kind test result yet.

## Other session notes

The first environment application reported:

```text
Error from server (NotFound): error when creating "cluster-state/limits.yaml": namespaces "debug-lab" not found
```

Once the namespace existed, rerunning `./scenario.sh up` created the
LimitRange. The files under `cluster-state/` were left unchanged.

The backend network check also failed during an intermediate verification.
A separate BusyBox probe subsequently resolved the Service and returned HTTP
200, and the final verifier passed that check. No extra backend change was
made for that intermediate result.

## Last verification result

```text
==> verifying goal state in namespace debug-lab
  PASS  migrate Job completed
  PASS  deployment backend: 1/1 ready
  PASS  deployment gateway: 1/1 ready
  PASS  deployment worker: 1/1 ready
  FAIL  deployment reporter: 0/1 ready
  PASS  deployment metrics: 1/1 ready
  PASS  no pods in CrashLoopBackOff
  PASS  ServiceAccount debug-lab/reporter can list pods
  PASS  backend answers on http://backend:8080/healthz
  PASS  gateway /status reports backend=ok
  FAIL  reporter /report does not return a pod count

2 check(s) failing, 9 passing. Keep digging — every failure is a symptom.
```

Part 4 is still incomplete: reporter readiness and its `/report` response need
to pass, and the chart needs a recorded run on kind.
