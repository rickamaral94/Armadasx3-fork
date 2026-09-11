# A740-QUIRKS

Capacidades, bugs e workarounds do Adreno 740, **por driver e faixa de versão**
— nunca por modelo de aparelho. Um bug é do driver; indexar por aparelho faz o
workaround sobreviver à correção do driver e persistir como custo permanente.

## Estado

A **tabela de capacidades ainda está vazia**: exige `vulkaninfo` rodado no
aparelho com os dois drivers, e isso não foi feito. O que está preenchido
abaixo são quirks **já documentados no código do upstream**, extraídos e
atribuídos — não medições próprias.

## Capacidades — a preencher (F1.1)

`tools/fork/device-probe.sh` ainda não existe. Ele precisa registrar, com
driver proprietário **e** Turnip:

- Extensões e features do Vulkan, limites, heaps de memória.
- Formatos suportados, em especial **BC1–BC3** (se ausente, a Fase 5 precisa de
  decode NEON ou compute shader) e **`D24_UNORM_S8_UINT`** (e qual é o fallback
  quando falta).
- Topologia de CPU: `cpu_capacity`, `scaling_max_freq`, `CPU part` por núcleo.
  A topologia esperada é 1× X3 + 2× A715 + 2× A710 + 3× A510, **a confirmar**.
- `HWCAP`/`HWCAP2`: `asimddp`, `i8mm`, `bf16`, `lse`, `crc32`, `sha3`, `sve`,
  `sve2`. **Não assumir SVE/SVE2 exposto.**
- Thermal zones, RAM total, `ro.build.version.sdk`.

## Quirks conhecidos

### Q1 — Driver proprietário Qualcomm vaza memória em `vkCmdEndRenderPass`

| | |
|---|---|
| Driver | proprietário Qualcomm |
| Turnip | não afetado |
| Origem | upstream, `rpcs3/Emu/RSX/VK/vkutils/device.cpp` |
| Estado | contornado no upstream |

`begin_conditional_rendering` insere uma barreira de memória de buffer, o que
encerra o render pass, e **cada `vkCmdEndRenderPass` faz o driver alocar memória
que não devolve**. Um heap profile de uma sessão de Skate 3 colocou as maiores
pilhas de alocação — 157, 152, 150 MB e mais — todas nesse caminho, via
`qglinternal::vkCmdEndRenderPass` para `calloc`. O processo chegou a 4,3 GB de
memória anônima, levou o aparelho a 54 MB livres com 3 GB em swap, e foi morto.
Cerca de 2,4 GB chegaram em oito segundos.

Não é heap nosso e não dá para liberar: o único recurso é parar de pedir. Sem a
extensão, o RSX cai em `thread::begin_conditional_rendering`, que simplesmente
executa os draws — resultados de oclusão deixam de culminar em corte, custando
trabalho de GPU em troca da sessão sobreviver.

**Um segundo caso do mesmo vazamento** aparece nos comentários de
`android/build-variants.sh`: Batman: Arkham City subindo monotonicamente até
7,1 GB e sendo morto pelo lowmemorykiller, **sem sinal em log nenhum**. O
`+fp16` chegou a ser suspeito e está inocentado — era isto. Vale como aviso de
método: um vazamento de driver se apresenta como "o build novo quebrou o jogo".

### Q2 — Turnip 26.0 perde o device em `vkCmdCopyQueryPoolResults` com `WAIT_BIT`

| | |
|---|---|
| Driver | Turnip 26.0 |
| Proprietário | não afetado por este |
| Aparelho da observação | Adreno 740 |
| Origem | upstream, mesmo arquivo |

Spider-Man: Web of Shadows perde o device Vulkan cerca de um minuto dentro do
gameplay. Foi reportado contra `poke_query` — **a primeira chamada que lê um
resultado, não a que causa o problema**. Esse caminho é o único lugar que grava
`vkCmdCopyQueryPoolResults` com `VK_QUERY_RESULT_WAIT_BIT`, que faz a própria
GPU bloquear até a query resolver.

Observado exatamente no hardware-alvo deste fork. Precisa de reprodução própria
e de issue no repositório do Turnip, com faixa de versão, antes de qualquer
workaround adicional.

### Q3 — Adreno não tem `VK_EXT_shader_uniform_buffer_unsized_array`

| | |
|---|---|
| Driver | ambos |
| Estado | corrigido no upstream |
| Origem | `rpcs3/Emu/RSX/VK/VKHelpers.h` |

O upstream do RPCS3 declara arrays em uniform blocks como não dimensionados
incondicionalmente, o que exige essa extensão. O Adreno não a tem, então **toda
pipeline de jogo falhava ao compilar (`VK_ERROR_UNKNOWN`) e nada além dos
overlays desenhava**. `ubo_array_dim()` agora emite `[]` quando há suporte e um
`[N]` concreto quando não há.

### Q4 — GPUs móveis rejeitam tipos float16 nativos em shader

| | |
|---|---|
| Driver | detectado em runtime, não por modelo |
| Estado | contornado no upstream |
| Origem | `rpcs3/Emu/RSX/VK/vkutils/device.cpp` |

O compilador de shader do driver rejeita float16 nativo; o upstream desabilita
`shader_types_support.allow_float16`. Substituir por float32 custa banda e
renderiza corretamente.

Não confundir com o `-march=...+fp16` do build, que é FP16 **de CPU** e é outra
coisa inteiramente — a confusão já custou uma investigação (ver Q1).

### Q5 — `wrap.<pacote>` é ignorado em build de usuário

| | |
|---|---|
| Escopo | Android, build não-debuggable |
| Estado | contornado |
| Origem | `android/src/rpcsx-android.cpp` |

A forma usual de setar variáveis de ambiente do Mesa (`TU_DEBUG` e afins) é a
propriedade `wrap.<pacote>`, que num build de usuário **pode ser escrita e lida
de volta sem nunca chegar ao processo** — uma flag que nunca se aplicou é
indistinguível de uma que não fez diferença.

O caminho que funciona é `driver_env.txt`, uma linha `NOME=VALOR` por vez, em:

    /sdcard/Android/data/com.armsx3.amaral/files/driver_env.txt

gravável por `adb` sem root. O diretório interno exigiria root ou pacote
debuggable.

> O pacote nesse caminho é derivado de `/proc/self/cmdline` desde o commit
> `2ac5a5c9`. Antes disso era o literal `com.armsx3`, então builds com outro
> `applicationId` — o flavor `play` do upstream inclusive — liam o diretório de
> outro app.

## Formato para novos quirks

```
### Q<n> — <sintoma em uma linha>

| driver | <proprietário|Turnip> |
| versões afetadas | <faixa> |
| versão que corrige | <ou "nenhuma ainda"> |
| issue no driver | <link, ou "não reportado"> |
| workaround | <o que o fork faz> |
| custo do workaround | <o que se perde> |
| como remover | <a condição que torna o workaround desnecessário> |
```

**Todo workaround precisa de faixa de versão e de condição de remoção.** Um
workaround sem condição de saída vira dívida permanente, e a regra da Fase 6 é
explícita: bug de driver encontrado vira issue no repositório do driver, com
repro mínimo. Nada de workaround silencioso.
