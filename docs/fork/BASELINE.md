# BASELINE

Números de referência do **upstream** ARMSX3, por jogo × driver × estado de
cache, no AYN Odin 2 Portal (QCS8550 / Adreno 740).

> **Estado: vazio. Nenhuma medição foi feita.**
>
> Este arquivo não contém números porque nenhum número existe ainda. Ele não
> será preenchido por estimativa, por analogia com outro aparelho, nem por
> valores citados em release notes. Um número só entra aqui depois de rodar no
> aparelho, com o protocolo abaixo respeitado.

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
