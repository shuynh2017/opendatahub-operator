# Enable Distributed Tracing for llm-d deployments

You can enable distributed tracing for your llm-d model deployments to gain visibility into the full request lifecycle — from the gateway, through the inference scheduler, and into the vLLM model server. Traces are collected and stored in the Red Hat build of Tempo, with a Jaeger UI for visualization.

## Prerequisites

- You have an OpenShift cluster on version `4.20` or later.

- You have installed the OpenShift CLI (`oc`).

- You have logged in as a user with cluster-admin privileges.

- Compatible AI accelerators are available in the cluster.

- You have installed the `Red Hat Connectivity Link` operator from OperatorHub. For more information on how to do this, refer to the [Red Hat official documentation](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.3/html/installing_on_openshift_container_platform/index) on installing it.

- You have the `Red Hat OpenShift Service Mesh 3` operator installed in your cluster. You should have this by default on any OpenShift cluster version `4.20` or later.
  
- You have installed {productname-long} {vernum}.

- A `DataScienceClusterInitialization` (DSCI) and `DataScienceCluster` (DSC) exist in your cluster, enabling the `llmisvc-controller-manager` and `kserve-controller-manager`. The `DataScienceClusterInitialization` gets created by the Red Hat OpenShift-AI operator out of the box for you. This is a sample excerpt from the `DataScienceCluster` manifest:

```yaml
apiVersion: datasciencecluster.opendatahub.io/v2
kind: DataScienceCluster
metadata:
  name: default-dsc
  labels:
    app.kubernetes.io/name: datasciencecluster
spec:
  components:
    kserve:
      managementState: "Managed"
      nim:
        managementState: "Managed"
      rawDeploymentServiceConfig: "Headed"
    ... # Other DSC components as desired
```

- No other `LLMInferenceService`s exist in the namespace you intend to deploy in (each namespace contains only one llm-d inference stack).

## Architecture Overview

The distributed tracing pipeline consists of three components:

1. **vLLM model server** — Instrumented with OpenTelemetry to emit trace spans for each inference request. The `--otlp-traces-endpoint` and `--collect-detailed-traces` flags enable this.
2. **Tempo** — Receives traces from vLLM (and the inference scheduler), stores traces and exposes a Jaeger UI for querying and visualizing them.

```
vLLM (--otlp-traces-endpoint) ──► Tempo ──► Jaeger UI
                                    ▲
Inference Scheduler (--tracing) ────┘
```

## Procedure

### Step 1 — Install the Red Hat build of Tempo operator

The Tempo operator provides the `TempoMonolithic` CRD, which deploys a single-process Tempo instance suitable for development and demo environments. Install it from the `redhat-operators` catalog:

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-tempo-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-tempo-operator
  namespace: openshift-tempo-operator
spec:
  upgradeStrategy: Default
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: tempo-product
  namespace: openshift-tempo-operator
spec:
  channel: stable
  installPlanApproval: Automatic
  name: tempo-product
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

Wait for the operator to be ready:

```bash
oc get csv -n openshift-tempo-operator -w
```

### Step 2 — Create the workload namespace

Because we only allow for one inference stack per namespace at this time, we will create the `distributed-tracing` namespace, although this should work for any namespace provided you adjust the manifests accordingly.

```bash
oc create ns distributed-tracing && oc project distributed-tracing
```

`oc` should respond by telling us our namespace was created and we are using that project:

```console
namespace/distributed-tracing created
Now using project "distributed-tracing" on server "https://api.example.com:443".
```

### Step 3 — Deploy the Tempo instance

Create a `TempoMonolithic` instance in the workload namespace. This stores traces in-memory and exposes a Jaeger UI via an OpenShift Route:

```bash
oc apply -f - <<'EOF'
apiVersion: tempo.grafana.com/v1alpha1
kind: TempoMonolithic
metadata:
  name: tracing
  namespace: distributed-tracing
spec:
  storage:
    traces:
      backend: memory
  jaegerui:
    enabled: true
    route:
      enabled: true
  ingestion:
    otlp:
      grpc:
        enabled: true
      http:
        enabled: true
EOF
```

Wait for Tempo to be ready:

```bash
oc get tempomonolithic tracing -n distributed-tracing -w
```

You should see the instance reach `Ready`:

```console
NAME      AGE
tracing   45s
```

Verify the Tempo pod is running:

```bash
oc get pods -n distributed-tracing -l app.kubernetes.io/instance=tracing
```

```console
NAME              READY   STATUS    RESTARTS   AGE
tempo-tracing-0   4/4     Running   0          60s
```

Some things to note about this Tempo setup:

1. **In-memory storage** — Traces are stored in memory and will be lost if the pod restarts. For production deployments, use `TempoStack` with object storage (e.g., S3 or ODF) instead.
2. **Jaeger UI** — The `jaegerui.enabled: true` and `jaegerui.route.enabled: true` settings deploy the Jaeger query UI and create an OpenShift Route. You can find the route with `oc get route -n distributed-tracing`.
3. **Multi-tenancy** — By default multi-tenancy is not enabled. OpenShift will emit a warning about this during creation. Enabling multi-tenancy (`multitenancy.enabled: true`, `mode: openshift`) adds auth to the ingest and query paths, but the Jaeger UI currently does not send the required `X-Scope-OrgID` tenant header, making the UI inaccessible. For demo purposes, leaving multi-tenancy disabled is recommended.

### Step 5 — Create the Gateway

Next we will create a gateway that uses TLS via OpenShift Service Mesh:

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: distributed-tracing-gateway-config
  namespace: distributed-tracing
data:
  service: |
    metadata:
      annotations:
        service.beta.openshift.io/serving-cert-secret-name: "distributed-tracing-gateway-tls"
    spec:
      type: ClusterIP
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: distributed-tracing-gateway
  namespace: distributed-tracing
spec:
  gatewayClassName: data-science-gateway-class
  infrastructure:
    parametersRef:
      group: ""
      kind: ConfigMap
      name: distributed-tracing-gateway-config
  listeners:
  - allowedRoutes:
      namespaces:
        from: Same
    name: https
    port: 443
    protocol: HTTPS
    tls:
      certificateRefs:
      - group: ""
        kind: Secret
        name: distributed-tracing-gateway-tls
      mode: Terminate
EOF
```

You should see:

```console
configmap/distributed-tracing-gateway-config created
gateway.gateway.networking.k8s.io/distributed-tracing-gateway created
```

Wait for the gateway to be programmed:

```bash
oc get gateway distributed-tracing-gateway -n distributed-tracing -w
```

```console
NAME                          CLASS                        ADDRESS   PROGRAMMED   AGE
distributed-tracing-gateway   data-science-gateway-class             True         30s
```

**Note:** We use `ClusterIP` as the service type because not all OpenShift flavours have `LoadBalancer` integration. For accessing the inference endpoint, you can use `kubectl port-forward` (as shown in the verification section) or send requests from a pod inside the cluster.

### Step 6 — Create the LLMInferenceService with tracing enabled

Now we create the `LLMInferenceService` with distributed tracing configured on both the inference scheduler and the vLLM model server:

```bash
oc apply -f - <<'EOF'
apiVersion: serving.kserve.io/v1alpha2
kind: LLMInferenceService
metadata:
  name: distributed-tracing-llama
  namespace: distributed-tracing
spec:
 tracing:
    exporterEndpoint: "http://tempo-tracing:4317"
    sampler: "parentbased_traceidratio"
    samplerArg: "0.05"
    exporter: "otlp"
  router:
    scheduler:
    route: {}
    gateway:
      refs:
      - name: distributed-tracing-gateway
        namespace: distributed-tracing
  model:
    uri: hf://Qwen/Qwen2.5-7B-Instruct
    name: Qwen/Qwen2.5-7B-Instruct
  template:
    containers:
      - name: main
        image: registry.redhat.io/rhaii-early-access/vllm-cuda-rhel9:3.5.0-ea.1-1780065492
        imagePullPolicy: Always
        resources:
          limits:
            cpu: '4'
            memory: 32Gi
            nvidia.com/gpu: 1
          requests:
            cpu: '2'
            memory: 16Gi
            nvidia.com/gpu: 1
EOF
```

Wait for the LLMISVC to be ready:

```bash
oc get llminferenceservice distributed-tracing-llama -n distributed-tracing -w
```

Some important pieces to note about this configuration:

1. **Sampling rate** — Both the scheduler and vLLM are configured with `OTEL_TRACES_SAMPLER=parentbased_traceidratio` and `OTEL_TRACES_SAMPLER_ARG=0.05`, meaning 5% of requests will be traced. This is appropriate for development and demo environments. For high-traffic production deployments, consider reducing this to 1-5%.

2. **Tempo endpoint** — the service `tempo-tracing:4317` created by the Tempo operator in step 3. This is the gRPC endpoint of the Tempo Collector.

## Verifying Distributed Tracing

### Sending test traffic

To verify that traces are flowing end-to-end, port-forward the gateway service and send a few requests:

```bash
# Find the gateway service name
GATEWAY_SVC=$(oc get svc -n distributed-tracing -l gateway.networking.k8s.io/gateway-name -o jsonpath='{.items[0].metadata.name}')

# Port-forward in the background
kubectl port-forward -n distributed-tracing "svc/$GATEWAY_SVC" 9443:443 &
PF_PID=$!
sleep 3

# Send requests (at 5% sampling, 26 requests gives ~75% chance of at least one trace)
TOKEN=$(oc whoami -t)
for i in $(seq 1 26); do
    HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' \
        --noproxy localhost \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        https://localhost:9443/distributed-tracing/distributed-tracing-llama/v1/chat/completions \
        -d '{"model":"Qwen/Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"Hello, request '"$i"'"}],"max_tokens":50}')
    echo "Request $i/13 — HTTP $HTTP_CODE"
done

# Stop port-forward
kill $PF_PID
```

All requests should return `HTTP 200`.

### Viewing traces in the Jaeger UI

Get the Jaeger UI route:

```bash
oc get route -n distributed-tracing -l app.kubernetes.io/name=tempo-monolithic
```

```console
NAME                     HOST/PORT                                                    PATH   SERVICES                 PORT     TERMINATION     WILDCARD
tempo-tracing-jaegerui   tempo-tracing-jaegerui-distributed-tracing.apps.example.com          tempo-tracing-jaegerui   16686    edge/Redirect   None
```

Open the `HOST/PORT` URL in your browser. In the Jaeger UI:

1. Select a service from the **Service** dropdown (e.g., `inference-server-decode` or `gateway-api-inference-extension`).
2. Click **Find Traces**.
3. Click on a trace to expand its span timeline.

You should see spans from both the inference scheduler and vLLM, showing the full request path through the llm-d stack.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Jaeger UI shows 0 services | traces can't reach Tempo | Check Tempo logs: `oc logs -l app.kubernetes.io/name=tempo-monolithic -n distributed-tracing -c tempo-query`. If you see `connection refused` errors, restart the Tempo pod: `oc delete pod -l app.kubernetes.io/name=tempo-monolithic -n distributed-tracing` |
| `missing tenant header` in Jaeger UI | Multi-tenancy is enabled on the Tempo instance | Disable multi-tenancy in the `TempoMonolithic` spec, or access Tempo directly bypassing the gateway |
| `GatewayPreconditionNotMet` on LLMISVC | llmisvc controller started before Connectivity Link CRDs were available | Restart the llmisvc controller pod: `oc rollout restart deployment llmisvc-controller-manager -n redhat-ods-applications` |
| Gateway shows `PROGRAMMED=False` | Service type is `LoadBalancer` but no LB controller exists | Change the gateway ConfigMap service type to `ClusterIP` |
