# Рекомендации по моделям для разных GPU

## Сетап 1: 12GB VRAM (RTX 5070)
**Рекомендуется**: Vikhr-3-4B
- vLLM FP8 16K: 6-9GB, 1808 TPS
- SGLang W8A8+FP8 KV 65K: ~10GB, 2286 TPS ✅
- llama.cpp Q4_K_M 32K: ~4GB, ~200 TPS
```bash
sglang --model Vikhr-3-4B --load-format int8 --kv-cache-dtype fp8_e5m2 --context-length 65536
```

## Сетап 2: 16GB VRAM (RTX A4000/4080/4090)
**Рекомендуется**: Vikhr-3-8B или Saiga-Llama3-8B
- vLLM FP8 16K: 11-14GB, 1186 TPS ✅
- SGLang W8A8 32K: ~15GB, 1357 TPS
- llama.cpp Q5_K_M 32K: ~9GB, ~250 TPS
```bash
vllm --model Vikhr-3-8B --quantization fp8 --max-model-len 16384 --gpu-memory-utilization 0.9
```

## Сетап 3: 24GB VRAM (Titan RTX/A5000)
**Рекомендуется**: Saiga-Nemo-12B
- vLLM FP8 16K: 13-15GB, 869 TPS ✅
- SGLang W8A8 65K: ~15GB, 223 TPS
- llama.cpp Q5_K_M 16K: ~14GB, ~150 TPS
```bash
vllm --model Saiga-Nemo-12B --quantization fp8 --max-model-len 16384 --gpu-memory-utilization 0.9
```

## Сетап 4: 32GB VRAM (RTX A6000)
**Рекомендуется**: Saiga-Nemo-12B FP16 (без квантизации)
- vLLM FP16 32K: ~28GB, ~950 TPS ✅
- vLLM FP16 16K: ~24GB, ~1100 TPS
```bash
vllm --model Saiga-Nemo-12B --max-model-len 32768 --gpu-memory-utilization 0.9
```

## Сетап 5: 2x16GB VRAM (Tensor Parallel)
**Рекомендуется**: lmdeploy для максимального throughput
- Nemo-12B lmdeploy TP2 32K: 15.8GB×2, 1268 TPS ✅
- Nemo-12B SGLang TP2+FP8 32K: 15.7GB×2, 1193 TPS
- Llama3-8B SGLang TP2+FP8 32K: 15.8GB×2, 1826 TPS
- Vikhr-3-4B lmdeploy TP2 32K: 14.8GB×2, 2553 TPS
```bash
CUDA_VISIBLE_DEVICES=0,1 lmdeploy serve api_server Saiga-Nemo-12B --tp 2
```

## Квантизация
- **FP16**: полная точность, 2 байта/параметр
- **FP8**: ~1% потери качества, 1 байт/параметр
- **W8A8/INT8**: ~2-3% потери, 1 байт/параметр
- **Q5/Q4 (GGUF)**: 3-5% потери, 0.5-0.7 байт/параметр
