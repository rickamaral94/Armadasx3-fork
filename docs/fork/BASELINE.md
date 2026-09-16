# BASELINE

Números de referência do **upstream** ARMSX3, por jogo × driver × estado de
cache, no AYN Odin 2 Portal (QCS8550 / Adreno 740).

> **Estado: sem números de performance. O ambiente está caracterizado; FPS não.**
>
> A captura de 2026-09-16 (abaixo) fixa aparelho, driver, build e topologia de
> CPU — tudo que um número precisa citar para ser comparável. Não fixa FPS nem
> frametime, porque o RSX Profiler estava desligado e o log não carrega tempo de
> quadro nenhum. Nada aqui será preenchido por estimativa, por analogia com
> outro aparelho, nem por valores de release notes.

---

## Captura 2 — 2026-09-16 15:03, com frametime

Mesma build, mesmo driver, mesmo jogo, `RSX Profiler` ligado. 44 relatórios de
300 quadros. **Uma sessão só — nada aqui é mediana de 5 runs ainda.**

| cena | ms/quadro | quadros >33 ms | quadros >100 ms | pior |
|---|---|---|---|---|
| menu (0:44–0:47) | 17,5 | 0–6 de 300 | 0 | 25–92 ms |
| jogo (0:47:11 em diante) | **121–140** | **100%** | 60–90% | **351 ms** |

**Atribuição: o lado convidado (SPU), não a GPU.** A thread RSX fica **39,8% do
quadro ociosa esperando FIFO**, enquanto o jogo registra 367 vezes
`BATCHJOB: AddJob: waiting for room in job list` e o perfil mostra ~200 mil
`PUTLLC` por quadro com 24% de falha. O detalhamento e a hipótese falsificável
estão em `PERF-LOG.md` (entrada de 2026-09-16).

Memória livre no fim: 7,2 GB — **sem pressão**, o que exclui vazamento (Q1) para
esta sessão.

---

## Captura 1 — 2026-09-16, ambiente (sem FPS)

Primeira execução do APK do fork em hardware. Fonte:
`armsx3-amaral-diag-20260916-1431.zip` (exportação de diagnóstico do próprio
app; 43k linhas de `ARMSX3.log`, dois boots, sessão de ~16 min).

| | |
|---|---|
| Build | `0.0.42-20663-9a0c23e2` Alpha, branch do fork, `type=Release march=armv8.2-a+dotprod+fp16 api=android-33 abi=arm64-v8a lto=OFF pgo=off` |
| Aparelho | AYN Odin 2 Portal (`kalama`), Android 13 (API 33), kernel 5.15.123 |
| SoC | QTI QCS8550 — 1× Cortex-X3 (`0xd4e`) + 2× A715 (`0xd4d`) + 2× A710 (`0xd47`) + 3× A510 (`0xd46`) |
| RAM | 11,0 GiB |
| GPU | Adreno 740 |
| **Driver** | **Turnip, Mesa 26.3.0-devel (`git-cab1821ef7`), driverID 18, conformance 1.4.0.0** — *não* o proprietário |
| `driver_env.txt` | ausente; nenhuma opção Mesa foi aplicada |
| Memória Vulkan | 8448 MB device-local = host-coherent = BAR (arquitetura unificada) |
| Depth-stencil | D24_UNORM_S8_UINT: sim; D32_SFLOAT_S8_UINT: sim |
| Extensões | 12 carregadas, incluindo `VK_EXT_shader_uniform_buffer_unsized_array` |
| Jogo | God of War III (BCUS98111), 239 pipelines compiladas |
| PGO | `off` — o build medido **não** tem PGO |

### O que isto já decide

- **Gate da Fase 0 cumprido.** O APK do fork instala com id próprio
  (`com.armsx3.amaral`), inicializa o core, sobe Vulkan, compila shaders, roda o
  jogo e encerra limpo. Nenhum crash, nenhum device loss, nenhum `VK_ERROR`.
- **A matriz de drivers começa pela coluna Turnip, não pela proprietária.** Toda
  linha desta captura vale para Turnip 26.3.0-devel e para mais nada.
- **Fallback de CPU não é o alvo.** Ver Fase 4 abaixo.

### Fase 4 — atribuição de fallback, primeira leitura

| Caminho | Resultado |
|---|---|
| `ppu_recompiler_fallback` (runtime, instrumentado pelo fork) | **zero** |
| `ppu_reservation_fallback` (runtime, por design) | **zero** |
| Blocos SPU que falharam ao compilar | **zero** |
| Despachos em blocos SPU falhos | **zero** |
| Blocos PPU compilados instrução-a-instrução (**compile time, upstream**) | 262 instruções, 20 blocos, 7 módulos |

As quatro primeiras linhas são da instrumentação da F4.A. A quinta é um aviso
antigo do upstream que a F4.A **não** cobre — é o tradutor LLVM desistindo de um
bloco em tempo de compilação, não o runtime caindo no interpretador. São
caminhos independentes, e este log mostra zero do primeiro tipo e 262 do
segundo.

262 instruções num jogo inteiro é ruído. **A conclusão vale nos dois caminhos: o
codegen de PPU não é onde está o tempo.** A Fase 4 precisa de perfil, não de
mais instrumentação de fallback.

### O que esta captura NÃO estabelece

- **Nenhum FPS, nenhum frametime, nenhum 1% low.** O `RSX Profiler` (Core
  settings, dinâmico) estava desligado, então não há bucket de tempo de quadro
  no log. Zero linhas `STALL:` significa "não medido", não "sem stutter".
- Nada sobre o driver proprietário.
- Nada sobre comportamento térmico sustentado: a sessão teve dois boots e três
  reconstruções de swapchain (troca de app), então não é uma janela contínua.

---

## Por que ainda está vazio

A Fase 1 exige medição em hardware real. O agente que escreve este repositório
trabalha num container sem `adb`, sem USB e sem aparelho. Pode construir a
ferramenta; não pode produzir os dados. **Quem mede é o operador do Odin 2.**

## O que precisa ser medido antes da Fase 2

Cada célula da matriz é: jogo × driver (proprietário, Turnip) × cache
(frio, quente), mínimo 5 execuções, reportar **mediana e dispersão**.

| Métrica | Como |
|---|---|
| FPS médio | overlay interno / log |
| Frametime p50 / p95 / p99, 1% low | trace com marcadores |
| Stutters > 50 ms | contagem por sessão |
| Tempo de CPU por thread (PPU, SPU, RSX, compilação, áudio, I/O) | simpleperf / Perfetto |
| Núcleo onde cada thread rodou, migrações, trocas de contexto | Perfetto |
| Frametime de GPU, `vkQueueSubmit`/frame, readbacks/frame | AGI ou marcadores próprios |
| Tempo até gameplay; tempo de compilação PPU/SPU | log |
| Throttling e consumo | `/sys` thermal zones |

**Sessões de 10–15 min.** Qualquer conclusão sobre performance real depende de
comportamento sustentado, não de pico em benchmark curto.

## Confounds que precisam ser registrados junto de cada medição

Sem isto o número não é comparável e não deve ser registrado:

- Modo de performance do Odin e perfil de ventoinha (fixos).
- Temperatura inicial do SoC abaixo do limiar; resfriamento entre runs.
- Bateria / carregando, brilho, apps em segundo plano.
- Driver GPU e versão exata.
- Cache de shader / PPU / SPU: **frio ou quente**, declarado.
- **Hash do build record** produzido por `tools/fork/build.sh` (JSON ao lado do
  APK) e hash do `config.yml` usado.

O build record já existe e carrega commit, variante, carimbo de build
(`type/march/api/abi/lto/pgo`), build id do core e sha256 do APK. Toda linha
desta tabela deve citar um.

## Formato de cada entrada

```
### <Jogo> — <título ID>
driver: <proprietário|Turnip> <versão>
build record: <arquivo json>
cache: <frio|quente>
runs: <n>

| métrica | mediana | min | max |
|---|---|---|---|
| ...

atribuição: <CPU-bound(PPU|SPU|RSX-CPU) | GPU-bound | sync-bound | compile-bound | I/O-bound | thermal-bound>
evidência da atribuição: <o que no perfil sustenta isso>
```

A linha de **atribuição** é o produto real da Fase 1. Sem ela, a Fase 2 estaria
otimizando por palpite.
