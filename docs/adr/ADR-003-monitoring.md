# ADR-003: Monitoring with Prometheus + Grafana on the same VM

**Status:** accepted (2026-09-04)

Prometheus scrapes vLLM (`/metrics` on 8000/8001/8002: request rate, latency, queue, KV-cache usage, tokens/s),
node_exporter (CPU/RAM/disk/network) and an NVIDIA exporter (GPU utilisation, VRAM, temperature, power).
Grafana provisions the datasource and dashboards from files in `ops/monitoring/` so nothing is click-configured.
Exposed at `https://grafana.skyops.lan` through Caddy. Retention 30 days; footprint < 1 GB RAM, no GPU.
Alternative rejected: pushing metrics to a SaaS (data leaves the office) or DCGM exporter (needs the container
toolkit and a datacenter driver feature set for full value).
