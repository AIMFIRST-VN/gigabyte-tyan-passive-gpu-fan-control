# Exact run commands — V620 / ROCm / llama.cpp (gpu-server)

Image: `ghcr.io/ggml-org/llama.cpp:server-rocm` · GPU: gfx1030 (V620) · Model: `ornith-1.0-35b-Q4_K_M.gguf`

Common GPU flags (required): `--device=/dev/kfd --device=/dev/dri --security-opt seccomp=unconfined --group-add video`

## 1. GPU visible in container?
```bash
docker run --rm --device=/dev/kfd --device=/dev/dri --security-opt seccomp=unconfined --group-add video \
  --entrypoint /opt/rocm/bin/rocminfo ghcr.io/ggml-org/llama.cpp:server-rocm | grep -E 'Name|gfx'
# expect: gfx1030
```

## 2. One-off benchmark
```bash
docker run --rm --device=/dev/kfd --device=/dev/dri --security-opt seccomp=unconfined --group-add video \
  -v /opt/models/llm-models:/models \
  --entrypoint /app/llama-bench ghcr.io/ggml-org/llama.cpp:server-rocm \
  -m /models/ornith-1.0-35b-Q4_K_M.gguf -ngl 99 -p 2048 -n 512
```

## 3. Inference server (optional, persistent)
```bash
docker run -d --name llama-server --restart unless-stopped \
  --device=/dev/kfd --device=/dev/dri --security-opt seccomp=unconfined --group-add video \
  -v /opt/models/llm-models:/models -p 8080:8080 \
  ghcr.io/ggml-org/llama.cpp:server-rocm \
  -m /models/ornith-1.0-35b-Q4_K_M.gguf -ngl 99 --host 0.0.0.0 --port 8080
```

## 4. 24h burn-in (persistent) → see `gpu-stress-full-throttle.sh` + the systemd units.

Notes:
- Add `-e HSA_OVERRIDE_GFX_VERSION=10.3.0` if ROCm doesn't auto-detect gfx1030.
- The image persists on disk across reboots; `systemctl enable docker` makes Docker start on boot.
